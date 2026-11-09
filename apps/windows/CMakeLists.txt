cmake_minimum_required(VERSION 3.25)

project(OpenSVNWindows VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(OPENSVN_BUILD_TESTS "Build the Windows core tests" ON)

include(FetchContent)

# Each dependency is pinned by URL and by SHA-256. The hash is not a formality:
# a gateway error page is served with HTTP 200 and an innocent file name, so
# without it the failure only surfaces later as an extraction error that says
# nothing about the network. With it, the mismatch is reported as what it is.
#
# pugixml comes from the tag archive, not the release asset. The v1.14 asset
# answered 504 from GitHub's release CDN -- once in CI and twice by hand --
# which is enough to turn `main` red over nothing, while the archive endpoint
# kept serving the same tag throughout. nlohmann/json stays on its release
# asset: that asset is a curated 110 KB package, where the repository archive
# is 8 MB for a header-only library.
FetchContent_Declare(
    pugixml
    URL https://github.com/zeux/pugixml/archive/refs/tags/v1.14.tar.gz
    URL_HASH SHA256=610f98375424b5614754a6f34a491adbddaaec074e9044577d965160ec103d2e
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
set(PUGIXML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(PUGIXML_BUILD_MULTI_HEADER OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(pugixml)

FetchContent_Declare(
    nlohmann_json
    URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
    URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
set(JSON_Install OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(nlohmann_json)

if(OPENSVN_BUILD_TESTS)
    FetchContent_Declare(
        googletest
        URL https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz
        URL_HASH SHA256=8ad598c73ad796e0d8280b082cebd82a630d73e73cd3c70057938a6501bba5d7
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
endif()

set(OPENSVN_CORE_SOURCES
    src/core/src/credentials.cpp
    src/core/src/discovery.cpp
    src/core/src/error_mapper.cpp
    src/core/src/errors.cpp
    src/core/src/journal.cpp
    src/core/src/json_contract.cpp
    src/core/src/models.cpp
    src/core/src/output_parser.cpp
    src/core/src/parsing.cpp
    src/core/src/process.cpp
    src/core/src/redaction.cpp
    src/core/src/service.cpp
    src/core/src/text.cpp
    src/core/src/write_gate.cpp
)

add_library(opensvn_core STATIC ${OPENSVN_CORE_SOURCES})
add_library(OpenSVN::Core ALIAS opensvn_core)

target_include_directories(opensvn_core PUBLIC src/core/include)
target_compile_features(opensvn_core PUBLIC cxx_std_20)
target_compile_definitions(opensvn_core PUBLIC
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS
)
target_compile_options(opensvn_core PRIVATE /W4 /utf-8 /permissive- /Zc:__cplusplus /FS)
target_link_libraries(opensvn_core PUBLIC
    pugixml::pugixml
    nlohmann_json::nlohmann_json
    Advapi32
    Bcrypt
)

add_library(opensvn_capi SHARED src/capi/capi.cpp)
add_library(OpenSVN::CAPI ALIAS opensvn_capi)

target_include_directories(opensvn_capi PUBLIC src/capi/include)
target_compile_features(opensvn_capi PUBLIC cxx_std_20)
target_compile_definitions(opensvn_capi PRIVATE
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS
    OPENSVN_CAPI_EXPORTS
)
target_compile_options(opensvn_capi PRIVATE /W4 /utf-8 /permissive- /Zc:__cplusplus /FS)
target_link_libraries(opensvn_capi PRIVATE OpenSVN::Core)
set_target_properties(opensvn_capi PROPERTIES OUTPUT_NAME "OpenSVN.Native")

add_executable(opensvn-probe src/probe/main.cpp)
target_compile_options(opensvn-probe PRIVATE /W4 /utf-8 /permissive- /Zc:__cplusplus /FS)
target_link_libraries(opensvn-probe PRIVATE OpenSVN::Core)

if(OPENSVN_BUILD_TESTS)
    add_executable(fake_svn tests/fake_svn.cpp)
    target_compile_options(fake_svn PRIVATE /W4 /utf-8 /permissive- /Zc:__cplusplus /FS)

    add_executable(opensvn_tests
        tests/test_models.cpp
        tests/test_parsing.cpp
        tests/test_errors.cpp
        tests/test_process.cpp
        tests/test_journal.cpp
        tests/test_write_gate.cpp
        tests/test_discovery.cpp
        tests/test_service.cpp
        tests/test_contract_json.cpp
        tests/test_capi.cpp
    )
    target_compile_options(opensvn_tests PRIVATE /W4 /utf-8 /permissive- /Zc:__cplusplus /FS)
    target_link_libraries(opensvn_tests PRIVATE OpenSVN::Core OpenSVN::CAPI GTest::gtest_main)
    target_compile_definitions(opensvn_tests PRIVATE
        OPENSVN_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../testdata"
        OPENSVN_FAKE_SVN_PATH="$<TARGET_FILE:fake_svn>"
    )
    add_dependencies(opensvn_tests fake_svn opensvn_capi)

    enable_testing()
    add_test(NAME opensvn_tests COMMAND opensvn_tests)
endif()
