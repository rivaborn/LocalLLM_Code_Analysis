#pragma once

#include "util.h"

namespace fixture {

enum class ShapeKind {
    kCircle,
    kRectangle,
    kTriangle,
};

class Shape {
public:
    explicit Shape(ShapeKind kind) : kind_(kind) {}
    virtual ~Shape() {}

    ShapeKind kind() const { return kind_; }
    virtual double area() const = 0;
    virtual double perimeter() const = 0;

private:
    ShapeKind kind_;
};

class Circle : public Shape {
public:
    Circle(Point center, double radius);

    double area() const override;
    double perimeter() const override;
    bool contains(const Point& p) const;

private:
    Point center_;
    double radius_;
};

class Rectangle : public Shape {
public:
    Rectangle(Point origin, double width, double height);

    double area() const override;
    double perimeter() const override;

private:
    Point origin_;
    double width_;
    double height_;
};

// Free functions exercised from main.cpp (incoming references).
double total_area(const Shape* const* shapes, int count);
const char* kind_name(ShapeKind kind);

} // namespace fixture

// Global-scope symbols: the extractor queries references only for
// top-level symbols (path without '/'), so these exercise the
// Incoming References section of the golden output.
int shapes_fixture_version();

class ShapeCounter {
public:
    ShapeCounter() : count_(0) {}
    void add() { count_ += 1; }
    int count() const { return count_; }

private:
    int count_;
};
