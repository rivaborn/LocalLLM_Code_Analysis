// Small self-contained fixture for the typescript profile smoke test.

export interface Point {
    x: number;
    y: number;
}

export abstract class Shape {
    abstract area(): number;
    abstract perimeter(): number;
}

export class Circle extends Shape {
    constructor(private center: Point, private radius: number) {
        super();
    }

    area(): number {
        return Math.PI * this.radius * this.radius;
    }

    perimeter(): number {
        return 2 * Math.PI * this.radius;
    }

    contains(p: Point): boolean {
        const dx = p.x - this.center.x;
        const dy = p.y - this.center.y;
        return dx * dx + dy * dy <= this.radius * this.radius;
    }
}

export function totalArea(shapes: Shape[]): number {
    return shapes.reduce((sum, s) => sum + s.area(), 0);
}
