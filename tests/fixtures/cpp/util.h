// Small self-contained helper header (no system includes, so clangd
// needs no standard library to parse this fixture).
#pragma once

namespace fixture {

constexpr double kPi = 3.14159265358979323846;

struct Point {
    double x;
    double y;
};

inline double square(double v) {
    return v * v;
}

inline double distance2(const Point& a, const Point& b) {
    return square(a.x - b.x) + square(a.y - b.y);
}

} // namespace fixture
