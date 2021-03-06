add_custom_command(OUTPUT ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.m
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMAND ${RAGEL} -G2 mod/box/memcached-grammar.rl
                     -o mod/box/memcached-grammar.m
    DEPENDS ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.rl)
# Do not clean memcached-grammar.m in 'make clean'.
set_property(DIRECTORY PROPERTY CLEAN_NO_CUSTOM true)
set_property(DIRECTORY PROPERTY ADDITIONAL_MAKE_CLEAN_FILES tmp.c box.lua.c)

add_custom_target(generate_memcached_grammar_m DEPENDS
    ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.m)

# Do not try to randomly re-generate memcached-grammar.m
# after a fresh checkout/branch switch.
execute_process(COMMAND ${CMAKE_COMMAND} -E touch_nocreate
    ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.m)

ADD_CUSTOM_COMMAND(OUTPUT ${CMAKE_BINARY_DIR}/mod/box/box.lua.c
    COMMAND ${ECHO} 'const char box_lua[] =' > tmp.c
    COMMAND ${CMAKE_BINARY_DIR}/extra/txt2c
        ${CMAKE_SOURCE_DIR}/mod/box/box.lua >> tmp.c
    COMMAND ${ECHO} '\;' >> tmp.c
    COMMAND ${CMAKE_COMMAND} -E copy_if_different tmp.c
        ${CMAKE_BINARY_DIR}/mod/box/box.lua.c
    COMMAND ${CMAKE_COMMAND} -E remove tmp.c
    DEPENDS ${CMAKE_SOURCE_DIR}/mod/box/box.lua)

add_custom_target(generate_box_lua_c
    DEPENDS ${CMAKE_BINARY_DIR}/mod/box/box.lua.c)

set_source_files_properties(memcached-grammar.m
    PROPERTIES HEADER_FILE_ONLY true)

set_source_files_properties(memcached.m
    PROPERTIES COMPILE_FLAGS "-Wno-uninitialized")

tarantool_module("box" tuple.m index.m tree.m space.m port.m request.m
    txn.m box.m box.lua.c box_lua.m memcached.m memcached-grammar.m)
