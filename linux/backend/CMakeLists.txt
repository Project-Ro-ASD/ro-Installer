cmake_minimum_required(VERSION 3.13)
project(ro_backend LANGUAGES CXX)

add_library(ro_backend SHARED installer_core.cpp)
target_compile_features(ro_backend PUBLIC cxx_std_17)
set_target_properties(ro_backend PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Ilerleyen asamalarda KPMCore eklenecek.
# target_link_libraries(ro_backend PRIVATE kpmcore)
