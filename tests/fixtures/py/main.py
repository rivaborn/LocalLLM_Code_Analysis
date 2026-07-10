"""Entry point exercising cross-file references for the smoke test."""

from shapes import Circle, Point, total_area


def build_scene():
    return [
        Circle(Point(0.0, 0.0), 2.0),
        Circle(Point(1.0, 1.0), 0.5),
    ]


def main():
    scene = build_scene()
    total = total_area(scene)
    inside = scene[0].contains(Point(1.0, 1.0))
    return 0 if total > 0 and inside else 1


if __name__ == "__main__":
    raise SystemExit(main())
