#include "shapes.h"

using fixture::Circle;
using fixture::Point;
using fixture::Rectangle;
using fixture::Shape;
using fixture::ShapeKind;

int main() {
    Circle c(Point{0.0, 0.0}, 2.0);
    Rectangle r(Point{1.0, 1.0}, 3.0, 4.0);

    const Shape* shapes[] = {&c, &r};
    double sum = fixture::total_area(shapes, 2);

    const char* name = fixture::kind_name(ShapeKind::kCircle);
    bool inside = c.contains(Point{1.0, 1.0});

    ShapeCounter counter;
    counter.add();
    counter.add();
    int version = shapes_fixture_version();

    // Return an exit code derived from the computations so nothing is
    // optimized away conceptually; value is irrelevant.
    return (sum > 0.0 && inside && name != nullptr &&
            counter.count() == 2 && version > 0) ? 0 : 1;
}
