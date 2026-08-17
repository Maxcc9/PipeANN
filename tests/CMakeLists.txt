add_executable(build_disk_index build_disk_index.cpp)
target_link_libraries(build_disk_index ${PROJECT_NAME})

add_executable(build_memory_index build_memory_index.cpp)
target_link_libraries(build_memory_index ${PROJECT_NAME})

# 這兩個 dynamic-index target 用到 DynamicIndex::save() 內的 MallocExtension::instance()
# (gperftools/tcmalloc)。原 CMake 只加 -DUSE_TCMALLOC 巨集卻沒 link 庫 → undefined reference。
# 只補在這兩個 target,不動 search/server binary。兩個眉角:
#  (1) 不能用 -ltcmalloc:conda/lib 的 -L 在前,會選到 conda 的 15KB stub(不含 MallocExtension);
#      改用 find_library 限定系統路徑,抓真正含符號的那顆(也較可攜)。
#  (2) 需 -Wl,--no-as-needed:conda LDFLAGS 帶 --as-needed,LTO .isra clone 的符號需求對它不可見。
if(USE_TCMALLOC)
	find_library(SYS_TCMALLOC NAMES tcmalloc
		PATHS /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /usr/local/lib NO_DEFAULT_PATH)
	if(NOT SYS_TCMALLOC)
		message(WARNING "USE_TCMALLOC=ON 但系統找不到含 MallocExtension 的 libtcmalloc;"
			"overall_performance/test_insert_search 可能 link 失敗(可設 -DUSE_TCMALLOC=OFF 略過)")
	endif()
endif()

add_executable(overall_performance overall_performance.cpp)
target_link_libraries(overall_performance ${PROJECT_NAME})
if(USE_TCMALLOC AND SYS_TCMALLOC)
	target_link_libraries(overall_performance -Wl,--no-as-needed ${SYS_TCMALLOC})
endif()

add_executable(test_insert_search test_insert_search.cpp)
target_link_libraries(test_insert_search ${PROJECT_NAME})
if(USE_TCMALLOC AND SYS_TCMALLOC)
	target_link_libraries(test_insert_search -Wl,--no-as-needed ${SYS_TCMALLOC})
endif()

add_executable(overall_perf_mem overall_perf_mem.cpp)
target_link_libraries(overall_perf_mem ${PROJECT_NAME})

add_executable(search_disk_index search_disk_index.cpp)
target_link_libraries(search_disk_index ${PROJECT_NAME})

add_executable(search_disk_index_mem search_disk_index_mem.cpp)
target_link_libraries(search_disk_index_mem ${PROJECT_NAME})

add_executable(pad_partition pad_partition.cpp)
target_link_libraries(pad_partition ${PROJECT_NAME})

add_executable(normalize_data normalize_data.cpp)
target_link_libraries(normalize_data ${PROJECT_NAME})

add_executable(build_disk_index_filtered build_disk_index_filtered.cpp)
target_link_libraries(build_disk_index_filtered ${PROJECT_NAME})

add_executable(search_disk_index_filtered search_disk_index_filtered.cpp)
target_link_libraries(search_disk_index_filtered ${PROJECT_NAME})

add_executable(search_server search_server.cpp)
target_link_libraries(search_server ${PROJECT_NAME})
