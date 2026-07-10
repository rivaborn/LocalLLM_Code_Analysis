// Package shapes is a small self-contained fixture for the go profile
// smoke test.
package shapes

import "math"

// Point is a 2D coordinate.
type Point struct {
	X float64
	Y float64
}

// Shape is anything with an area and a perimeter.
type Shape interface {
	Area() float64
	Perimeter() float64
}

// Circle implements Shape.
type Circle struct {
	Center Point
	Radius float64
}

func (c Circle) Area() float64 {
	return math.Pi * c.Radius * c.Radius
}

func (c Circle) Perimeter() float64 {
	return 2 * math.Pi * c.Radius
}

// Contains reports whether p falls inside the circle.
func (c Circle) Contains(p Point) bool {
	dx := p.X - c.Center.X
	dy := p.Y - c.Center.Y
	return dx*dx+dy*dy <= c.Radius*c.Radius
}

// TotalArea sums the area of every shape.
func TotalArea(shapes []Shape) float64 {
	total := 0.0
	for _, s := range shapes {
		total += s.Area()
	}
	return total
}
