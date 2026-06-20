// PipeANN TCP search server
//
// Wire protocol identical to DiskANN search_server so pareto_client.py works unchanged.
//
// Usage:
//   search_server <data_type> <index_prefix> <port> <num_threads> <pipeline_width>
//                 [--mem_l <N>] [--mode <0|2>]
//
//   data_type      : uint8 / int8 / float
//   index_prefix   : path prefix used when building the index
//   port           : TCP listen port
//   num_threads    : worker threads (= max concurrent requests)
//   pipeline_width : I/O pipeline width passed to pipe_search (recommend 32)
//   --mem_l N      : load _mem.index and use mem_L=N for nav-graph entry (default 0)
//   --mode  M      : 0=beam_search  2=pipe_search (default 2)

#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <omp.h>

#include "ssd_index.h"
#include "nbr/nbr.h"
#include "utils/log.h"
#include "linux_aligned_file_reader.h"

// ── Wire protocol (matches DiskANN search_server exactly) ──────────────────
#pragma pack(push, 1)
struct RequestHeader {
    uint32_t query_id;
    uint32_t k;
    uint32_t l;
    float    et_theta;   // ignored by PipeANN (no θ-ET); kept for protocol compat
};
struct ResponseHeader {
    uint32_t query_id;
    uint64_t server_us;
};
#pragma pack(pop)
static_assert(sizeof(RequestHeader)  == 16, "");
static_assert(sizeof(ResponseHeader) == 12, "");

// ── I/O helpers ─────────────────────────────────────────────────────────────
static bool recv_all(int fd, void *buf, size_t len) {
    auto *p = static_cast<uint8_t *>(buf);
    size_t done = 0;
    while (done < len) {
        ssize_t n = ::recv(fd, p + done, len - done, 0);
        if (n == 0) return false;
        if (n < 0) { if (errno == EINTR) continue; return false; }
        done += static_cast<size_t>(n);
    }
    return true;
}
static bool send_all(int fd, const void *buf, size_t len) {
    const auto *p = static_cast<const uint8_t *>(buf);
    size_t done = 0;
    while (done < len) {
#ifdef MSG_NOSIGNAL
        ssize_t n = ::send(fd, p + done, len - done, MSG_NOSIGNAL);
#else
        ssize_t n = ::send(fd, p + done, len - done, 0);
#endif
        if (n < 0) { if (errno == EINTR) continue; return false; }
        done += static_cast<size_t>(n);
    }
    return true;
}

// ── Server ───────────────────────────────────────────────────────────────────
template <typename T>
class PipeANNServer {
public:
    PipeANNServer(const std::string &index_prefix, uint32_t num_threads,
                  uint64_t pipeline_width, uint32_t mem_l, int search_mode,
                  uint64_t data_dim)
        : _num_threads(num_threads), _pipeline_width(pipeline_width),
          _mem_l(mem_l), _search_mode(search_mode), _dim(data_dim)
    {
        _reader = std::make_shared<LinuxAlignedFileReader>();
        pipeann::Metric metric = pipeann::Metric::L2;
        pipeann::AbstractNeighbor<T> *nbr_handler =
            pipeann::get_nbr_handler<T>(metric, "pq");

        pipeann::IndexBuildParameters idx_params;
        idx_params.max_nthreads = num_threads;

        _index.reset(new pipeann::SSDIndex<T>(metric, _reader, nbr_handler,
                                               /*tags_flag=*/true, &idx_params));

        int rc = _index->load(index_prefix.c_str(), /*load_tags=*/false);
        if (rc != 0)
            throw std::runtime_error("Failed to load index: " + index_prefix);

        if (mem_l > 0) {
            std::string mem_path = index_prefix + "_mem.index";
            LOG(INFO) << "Loading memory index: " << mem_path;
            _index->load_mem_index(mem_path);
        }

        std::cout << "[PipeANN Server] index loaded, dim=" << _dim
                  << " threads=" << num_threads
                  << " pipeline_width=" << pipeline_width
                  << " mem_l=" << mem_l
                  << " mode=" << search_mode << std::endl;
    }

    void run(uint16_t port) {
        const int listen_fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listen_fd < 0)
            throw std::runtime_error("socket() failed");

        int reuse = 1;
        ::setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

        sockaddr_in addr{};
        addr.sin_family      = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port        = htons(port);

        if (::bind(listen_fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0)
            throw std::runtime_error(std::string("bind() failed: ") + strerror(errno));
        if (::listen(listen_fd, static_cast<int>(_num_threads * 16)) < 0)
            throw std::runtime_error(std::string("listen() failed: ") + strerror(errno));

        std::cout << "[PipeANN Server] listening on port " << port << std::endl;

        // Worker thread pool: each thread loops accept → handle → loop
        std::vector<std::thread> workers;
        workers.reserve(_num_threads);
        for (uint32_t i = 0; i < _num_threads; ++i) {
            workers.emplace_back([this, listen_fd]() {
                while (true) {
                    sockaddr_in client_addr{};
                    socklen_t client_len = sizeof(client_addr);
                    const int client_fd = ::accept(
                        listen_fd,
                        reinterpret_cast<sockaddr *>(&client_addr),
                        &client_len);
                    if (client_fd < 0) {
                        if (errno == EINTR || errno == ECONNABORTED) continue;
                        break;  // server shutting down
                    }
                    try {
                        handle_client(client_fd);
                    } catch (const std::exception &e) {
                        std::cerr << "[worker] " << e.what() << "\n";
                    }
                    ::close(client_fd);
                }
            });
        }
        for (auto &w : workers) w.join();
        ::close(listen_fd);
    }

private:
    void handle_client(int client_fd) {
        RequestHeader req{};
        if (!recv_all(client_fd, &req, sizeof(req)))
            throw std::runtime_error("failed to read request header");
        if (req.k == 0 || req.l == 0 || req.k > req.l)
            throw std::runtime_error("invalid request k/l");

        // Read query as float32 (pareto_client.py sends float32)
        std::vector<float> query_f(_dim, 0.0f);
        if (!recv_all(client_fd, query_f.data(), _dim * sizeof(float)))
            throw std::runtime_error("failed to read query vector");

        // Cast to T
        std::vector<T> query(_dim);
        for (uint64_t i = 0; i < _dim; ++i)
            query[i] = static_cast<T>(query_f[i]);

        std::vector<uint32_t> result_tags(req.k, 0);
        std::vector<float>    result_dists(req.k, 0.0f);
        pipeann::QueryStats   stats{};

        const auto t0 = std::chrono::steady_clock::now();

        if (_search_mode == 2) {
            _index->pipe_search(query.data(), req.k, _mem_l, req.l,
                                result_tags.data(), result_dists.data(),
                                _pipeline_width, &stats);
        } else {
            _index->beam_search(query.data(), req.k, _mem_l, req.l,
                                result_tags.data(), result_dists.data(),
                                _pipeline_width, &stats);
        }

        const auto t1 = std::chrono::steady_clock::now();
        const uint64_t server_us = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count());

        // Response: header + k uint64 IDs + k float dists
        ResponseHeader resp_hdr{req.query_id, server_us};
        std::vector<uint64_t> ids64(req.k);
        for (uint32_t i = 0; i < req.k; ++i)
            ids64[i] = static_cast<uint64_t>(result_tags[i]);

        const size_t resp_size = sizeof(resp_hdr)
                               + req.k * sizeof(uint64_t)
                               + req.k * sizeof(float);
        std::vector<uint8_t> response(resp_size);
        size_t off = 0;
        std::memcpy(response.data() + off, &resp_hdr,         sizeof(resp_hdr));         off += sizeof(resp_hdr);
        std::memcpy(response.data() + off, ids64.data(),      req.k * sizeof(uint64_t)); off += req.k * sizeof(uint64_t);
        std::memcpy(response.data() + off, result_dists.data(), req.k * sizeof(float));

        if (!send_all(client_fd, response.data(), response.size()))
            throw std::runtime_error("failed to send response");
    }

    std::shared_ptr<AlignedFileReader> _reader;
    std::unique_ptr<pipeann::SSDIndex<T>> _index;
    uint32_t _num_threads;
    uint64_t _pipeline_width;
    uint32_t _mem_l;
    int      _search_mode;
    uint64_t _dim;
};

// ── main ─────────────────────────────────────────────────────────────────────
int main(int argc, char **argv) {
    if (argc < 7) {
        std::cerr << "Usage: " << argv[0]
                  << " <data_type(uint8/int8/float)> <index_prefix> <port>"
                     " <num_threads> <pipeline_width> <data_dim>"
                     " [--mem_l N] [--mode 0|2]\n";
        return 1;
    }

    std::string data_type    = argv[1];
    std::string index_prefix = argv[2];
    uint16_t    port         = static_cast<uint16_t>(std::stoi(argv[3]));
    uint32_t    num_threads  = static_cast<uint32_t>(std::stoi(argv[4]));
    uint64_t    pipe_width   = static_cast<uint64_t>(std::stoi(argv[5]));
    uint64_t    data_dim     = static_cast<uint64_t>(std::stoi(argv[6]));
    uint32_t    mem_l        = 0;
    int         search_mode  = 2;

    for (int i = 7; i < argc; ++i) {
        if (std::string(argv[i]) == "--mem_l" && i + 1 < argc)
            mem_l = static_cast<uint32_t>(std::stoi(argv[++i]));
        else if (std::string(argv[i]) == "--mode" && i + 1 < argc)
            search_mode = std::stoi(argv[++i]);
    }

    omp_set_num_threads(static_cast<int>(num_threads));

    try {
        if (data_type == "uint8") {
            PipeANNServer<uint8_t> srv(index_prefix, num_threads, pipe_width,
                                       mem_l, search_mode, data_dim);
            srv.run(port);
        } else if (data_type == "int8") {
            PipeANNServer<int8_t> srv(index_prefix, num_threads, pipe_width,
                                      mem_l, search_mode, data_dim);
            srv.run(port);
        } else if (data_type == "float") {
            PipeANNServer<float> srv(index_prefix, num_threads, pipe_width,
                                     mem_l, search_mode, data_dim);
            srv.run(port);
        } else {
            std::cerr << "Unknown data_type: " << data_type << "\n";
            return 1;
        }
    } catch (const std::exception &e) {
        std::cerr << "Fatal: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
