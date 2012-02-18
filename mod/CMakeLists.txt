
function(tarantool_module mod)
  set (module_sources ${ARGV})
  list(REMOVE_ITEM module_sources ${mod})
  set_source_files_properties(
      ${CMAKE_SOURCE_DIR}/cfg/tarantool_${mod}_cfg.c
      PROPERTIES COMPILE_FLAGS "-Wno-unused" GENERATED True)
  set_source_files_properties(${recompiled_core_sources} PROPERTIES
      COMPILE_FLAGS "-fgnu-runtime")
  set_source_files_properties(${module_sources} PROPERTIES
      COMPILE_FLAGS "-fgnu-runtime")
  add_executable(tarantool_${mod}
      ${module_sources}
      ${CMAKE_SOURCE_DIR}/cfg/tarantool_${mod}_cfg.c)

  add_library(lt${mod} STATIC ${recompiled_core_sources})
  set_target_properties(lt${mod} PROPERTIES COMPILE_FLAGS
    "${core_cflags} -DTARANTOOL_CONFIG='<cfg/tarantool_${mod}_cfg.h>'")
  add_dependencies(lt${mod} generate_headers generate_admin_m)

  target_link_libraries(tarantool_${mod} lt${mod} ${common_libraries})
  set_target_properties(tarantool_${mod} PROPERTIES COMPILE_FLAGS
      "${core_cflags}")
  if(TARGET_OS_DARWIN)
    set_target_properties(tarantool_${mod} PROPERTIES LINK_FLAGS
        "-fgnu-runtime -pagezero_size 0x1000 -sectcreate __DATA __box_lua box.lua")
  endif()

  if (ENABLE_STATIC)
      set_target_properties(tarantool_${mod} PROPERTIES
          LINK_SEARCH_END_STATIC ON)
  endif()

  install (TARGETS tarantool_${mod} DESTINATION bin)

endfunction()

foreach (module ${TARANTOOL_MODULES})
  add_subdirectory(${module})
endforeach()
