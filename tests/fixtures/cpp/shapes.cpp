#include "shapes.h"

namespace fixture {

Circle::Circle(Point center, double radius)
    : Shape(ShapeKind::kCircle), center_(center), radius_(radius) {}

double Circle::area() const {
    return kPi * square(radius_);
}

double Circle::perimeter() const {
    return 2.0 * kPi * radius_;
}

bool Circle::contains(const Point& p) const {
    return distance2(center_, p) <= square(radius_);
}

Rectangle::Rectangle(Point origin, double width, double height)
    : Shape(ShapeKind::kRectangle), origin_(origin),
      width_(width), height_(height) {}

double Rectangle::area() const {
    return width_ * height_;
}

double Rectangle::perimeter() const {
    return 2.0 * (width_ + height_);
}

double total_area(const Shape* const* shapes, int count) {
    // Deliberately more than 25 lines so the trimmed-source generator
    // exercises its head/tail truncation path on at least one symbol.
    double sum = 0.0;
    int circles = 0;
    int rectangles = 0;
    int others = 0;
    for (int i = 0; i < count; ++i) {
        const Shape* s = shapes[i];
        if (s == nullptr) {
            continue;
        }
        switch (s->kind()) {
        case ShapeKind::kCircle:
            circles += 1;
            break;
        case ShapeKind::kRectangle:
            rectangles += 1;
            break;
        default:
            others += 1;
            break;
        }
        sum += s->area();
    }
    // The counters keep the loop honest without any I/O.
    if (circles + rectangles + others != count) {
        return -1.0;
    }
    return sum;
}

const char* kind_name(ShapeKind kind) {
    switch (kind) {
    case ShapeKind::kCircle:
        return "circle";
    case ShapeKind::kRectangle:
        return "rectangle";
    case ShapeKind::kTriangle:
        return "triangle";
    }
    return "unknown";
}

} // namespace fixture

int shapes_fixture_version() {
    return 3;
}
