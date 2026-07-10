// Entry point exercising cross-file references for the smoke test.

import { Circle, Point, totalArea } from "./shapes";

function buildScene(): Circle[] {
    return [
        new Circle({ x: 0, y: 0 }, 2),
        new Circle({ x: 1, y: 1 }, 0.5),
    ];
}

export function run(): number {
    const scene = buildScene();
    const total = totalArea(scene);
    const p: Point = { x: 1, y: 1 };
    return total > 0 && scene[0].contains(p) ? 0 : 1;
}
