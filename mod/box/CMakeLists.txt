add_custom_command(OUTPUT ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.m
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMAND ${RAGEL} -G2 mod/box/memcached-grammar.rl
                     -o mod/box/memcached-grammar.m
    DEPENDS ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.rl)

# Do not clean memcached-grammar.m in 'make clean'.
set_property(DIRECTORY PROPERTY CLEAN_NO_CUSTOM true)

add_custom_target(generate_memcached_grammar_m DEPENDS
    ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.m)

# Do not try to randomly re-generate memcached-grammar.m
# after a fresh checkout/branch switch.
execute_process(COMMAND ${CMAKE_COMMAND} -E touch_nocreate
    ${CMAKE_SOURCE_DIR}/mod/box/memcached-grammar.m)

set_source_files_properties(memcached-grammar.m
    PROPERTIES HEADER_FILE_ONLY true)

set_source_files_properties(memcached.m
    PROPERTIES COMPILE_FLAGS "-Wno-uninitialized")

if(TARGET_OS_DARWIN)
    set(module_link_flags "-pagezero_size 0x1000 -sectcreate __DATA __box_lua box.lua")
else()
    set(module_link_flags "box.lua.o")

    set_property(DIRECTORY PROPERTY ADDITIONAL_MAKE_CLEAN_FILES box.lua.o)
    set_source_files_properties(box.lua.o PROPERTIES EXTERNAL_OBJECT true)
    add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/box.lua.o
        COMMAND cd ${CMAKE_SOURCE_DIR}/mod/box && ${LD} -r -b binary box.lua -o ${CMAKE_CURRENT_BINARY_DIR}/box.lua.o
        DEPENDS box.lua)
endif()

tarantool_module("box" tuple.m index.m tree.m box.m box_lua.m
    memcached.m memcached-grammar.m)
