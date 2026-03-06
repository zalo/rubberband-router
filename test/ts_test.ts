// Run the same test cases as ruby_reference.rb and compare
import { booleanCrossProduct2D, getTangents, normalDistanceLineSegmentPointSquared } from '../src/geometry';

// Test 1: Cross product
const cpCases: [number,number,number,number,number,number][] = [
  [100, 0, 0, 100, 0, 0],
  [0, 100, 100, 0, 0, 0],
  [100, 0, 200, 0, 0, 0],
  [50, 50, 100, 100, 0, 0],
  [100, 50, 50, 100, 75, 75],
  [-50, 30, 40, -60, 10, 20],
  [1000, 500, 500, 1000, 750, 750],
];
const cpResults = cpCases.map(args => booleanCrossProduct2D(...args));

// Test 2: Tangents
const tanCases: [number,number,number,boolean,number,number,number,boolean][] = [
  [0, 0, 100, true, 500, 0, 100, true],
  [0, 0, 100, false, 500, 0, 100, false],
  [0, 0, 100, true, 500, 0, 100, false],
  [0, 0, 50, true, 300, 400, 50, true],
  [100, 200, 30, false, 400, 100, 60, true],
];
const tanResults = tanCases.map(args => getTangents(...args));

// Test 3: new_bor_list equivalent
function newBorListTest(ax:number, ay:number, bx:number, by:number, nx:number, ny:number, neighbors:[number,number][]) {
  const dax = ax-nx, day = ay-ny, dbx = bx-nx, dby = by-ny;
  const turn = booleanCrossProduct2D(ax, ay, bx, by, nx, ny);
  return neighbors.filter(([ex, ey]) => {
    const dex = ex-nx, dey = ey-ny;
    if (turn) return dax*dey > day*dex && dex*dby > dey*dbx;
    else return dax*dey < day*dex && dex*dby < dey*dbx;
  });
}
const neighbors1: [number,number][] = [[200,100],[100,200],[50,50],[150,150],[0,100]];
const borResult = newBorListTest(300, 100, 100, 300, 200, 200, neighbors1);

// Test 4: full_split equivalent
function fullSplitTest(arx:number, ary:number, brx:number, bry:number, nvx:number, nvy:number, neighbors:[number,number][]) {
  const v1x = arx-nvx, v1y = ary-nvy, v2x = brx-nvx, v2y = bry-nvy;
  const turn = booleanCrossProduct2D(arx, ary, brx, bry, nvx, nvy);
  const l: [number,number][] = [], r: [number,number][] = [];
  for (const [erx, ery] of neighbors) {
    const ex = erx-nvx, ey = ery-nvy;
    if (turn ? v1x*ey > v1y*ex && v2x*ey < v2y*ex : v1x*ey > v1y*ex || v2x*ey < v2y*ex) {
      l.push([erx, ery]);
    } else {
      r.push([erx, ery]);
    }
  }
  return [r, l];
}
const neighbors2: [number,number][] = [[150,50],[50,150],[250,250],[50,50],[200,100]];
const splitResult = fullSplitTest(100, 0, 0, 100, 100, 100, neighbors2);

// Test 5: normal distance
const ndResults = [
  normalDistanceLineSegmentPointSquared(0, 0, 100, 0, 50, 30, 999999),
  normalDistanceLineSegmentPointSquared(0, 0, 100, 0, 150, 30, 999999),
  normalDistanceLineSegmentPointSquared(0, 0, 100, 100, 50, 0, 999999),
];

const results = {
  cross_product: cpResults,
  tangents: tanResults,
  bor_list: borResult,
  full_split: splitResult,
  normal_dist: ndResults
};

console.log(JSON.stringify(results));
