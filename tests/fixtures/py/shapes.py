"""Small self-contained fixture for the python profile smoke test."""

import math
from dataclasses import dataclass


@dataclass
class Point:
    x: float
    y: float


class Shape:
    def area(self):
        raise NotImplementedError

    def perimeter(self):
        raise NotImplementedError


class Circle(Shape):
    def __init__(self, center, radius):
        self.center = center
        self.radius = radius

    def area(self):
        return math.pi * self.radius ** 2

    def perimeter(self):
        return 2.0 * math.pi * self.radius

    def contains(self, p):
        dx = p.x - self.center.x
        dy = p.y - self.center.y
        return dx * dx + dy * dy <= self.radius ** 2


def total_area(shapes):
    return sum(s.area() for s in shapes)
