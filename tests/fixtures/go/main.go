// Entry point exercising cross-file references for the smoke test.
package shapes

import (
	"fmt"
	"math"
)

// Describe renders a scene summary; calls into shapes.go symbols so the
// extraction picks up incoming references.
func Describe() string {
	scene := []Shape{
		Circle{Center: Point{X: 0, Y: 0}, Radius: 2},
		Circle{Center: Point{X: 1, Y: 1}, Radius: 0.5},
	}
	total := TotalArea(scene)
	rounded := math.Round(total*100) / 100
	return fmt.Sprintf("total area: %v", rounded)
}
