# Up to date with mapbox/Delaunator at b220a46cf974f4ef6e302d028379df916f53766a June 4, 2023
#                 mourner/robust-predicates c20b0ab9ab4c4f2969f3611908c41ce76aa0e7a7 May 25, 2023

## `Delaunator-Nim <https://github.com/patternspandemic/delaunator-nim>`_ is a
## port of `Mapbox/Delaunator <https://github.com/mapbox/delaunator>`_, a fast
## library for 2D Delaunay triangulation. In addition, this port includes a set
## of `helpers <helpers.html>`_ for utilizing the structures of a Delaunator object, as well as
## clipping of infinite regions of the Voronoi diagram.
##
## A Delaunator object is constructed from a set of points (aka 'sites'), and
## contains two key compact sequences of integers, *triangles* and *halfedges*.
## This representation of the triangulation, while less convenient, is what
## makes the library fast.
##
## Delaunator construction can originate from a flat seq of coordinates,

runnableExamples:
  var
    # A flat seq of `float64` coordinates
    coords = @[63.59410858154297, 198.1050262451172, 215.7989349365234, 171.0301208496094,
               33.8256950378418,  261.359130859375, 40.81229019165039, 61.88509368896484,
               189.6730651855469, 168.2080078125, 247.6787414550781, 222.6421508789062,
               265.9251403808594, 81.62255096435547, 21.60958862304688, 253.6200256347656,
               24.65586090087891, 67.60309600830078, 27.14787483215332, 113.4554977416992]
    # Construct
    d = delaunator.fromCoords[float64](coords)

  # Triplets of site ids.
  echo d.triangles

## **Output:**
##
## .. code-block:: nim
##   @[4, 5, 1, 4, 0, 5, 5, 6, 1, 1, 6, 4, 4, 9, 0, 0, 2, 5, 0, 7, 2, 3, 9, 4, 0, 9, 7, 6, 3, 4, 3, 8, 9, 9, 8, 7]
##
## or from some pairwise sequence, with conversion to a float type,

runnableExamples:
  var
    # A pairwise seq of `int` points
    points = @[
      [63, 198], [215, 171], [33,  261], [40, 61], [189, 168],
      [247, 222], [265, 81], [21, 253], [24, 67], [27, 113]
    ]
    # Construct into `float32` coordinates
    d = delaunator.fromPoints[array[2, int], float32](points)

  # Halfedges of triangulation.
  echo d.halfedges

## **Output:**
##
## .. code-block:: nim
##   @[5, 8, 11, 14, 17, 0, -1, 9, 1, 7, 29, 2, 22, 24, 3, 20, -1, 4, 26, -1, 15, 32, 12, 28, 13, 35, 18, -1, 23, 10, -1, 33, 21, 31, -1, 25]
##
## Construction from custom types is aided by `fromCustom`.
##
## Both fields, *triangles* and *halfedges* are sequences indexed by **halfedge**
## id. Importantly, notice that some halfedges index to '-1'. These halfedges have
## no opposite because they reside on the triangulation's hull. To quote Mapbox's
## guide to `Delaunator's data structures <https://mapbox.github.io/delaunator/>`_:
##
##   A triangle edge may be shared with another triangle. Instead of thinking
##   about each edge A ↔︎ B, we will use two half-edges A → B and B → A. Having
##   two half-edges is the key to everything this library provides.
##
##   Half-edges e are the indices into both of delaunator’s outputs:
##   * delaunay.triangles[e] returns the point id where the half-edge starts
##   * delaunay.halfedges[e] returns the opposite half-edge in the adjacent triangle, or -1 if there is no adjacent triangle
##
##   Triangle ids and half-edge ids are related.
##   * The half-edges of triangle t are 3 * t, 3 * t + 1, and 3 * t + 2.
##   * The triangle of half-edge id e is floor(e/3).
##
## The above linked guide is still very applicable to this port, and the helpers
## described therein, along with many more, are implemented in `delaunator/helpers <helpers.html>`_

# TODO: definitions, i.e. 'site', point, etc

# TODO: Consider using int64 for type of halfedge indice, due to their use as
# index into triangles to reference points. As int32, they'd be unable to ref
# a point in a set larger than high(int32). A signed type is required by
# halfedges, as it uses '-1' to mark hull complements.


import std/[math, tables]
from std/fenv import epsilon
from std/algorithm import fill

import delaunator/orient2d


var EDGE_STACK: array[512, uint32]

type
  Delaunator*[T] = ref object
    ## This object holds the datastructures neccessary to build and navigate the
    ## Delaunay-Voronoi dual graph.
    coords*: seq[T]               ## Flattened sequence of site points.
    minX*, minY*, maxX*, maxY*: T ## Extents of *coords*.
    triangles*: seq[uint32]       ## Sequence of triplet indices into *coords* defining delaunay triangulation.
    halfedges*: seq[int32]        ## Sequence of complement halfedges to that of the index.
    hull*: seq[uint32]            ## Sequence of point ids comprising the triangulation's hull.
    vectors*: seq[T]              ## Sequence of rays emanating from each triangle circumcenter adjacent to a hull site. Used for clipping infinite Voronoi regions.
    bounds*: tuple[minX, minY, maxX, maxY: T] ## Clipping bounds for the infinate Voronoi regions.

    # Arrays that will store the triangulation graph
    trianglesLen: int32
    d_triangles: seq[uint32]
    d_halfedges: seq[int32]

    # Temporary arrays for tracking the edges of the advancing convex hull
    d_hashSize: int
    d_hullStart: int
    d_hullPrev: seq[uint32]  # edge to prev edge
    d_hullNext: seq[uint32]  # edge to next edge
    d_hullTri:  seq[uint32]  # edge to adjacent triangle
    d_hullHash: seq[int32]   # angular edge hash

    # Temporary arrays for sorting points
    d_ids:   seq[uint32]
    d_dists: seq[T]

    # For fast lookup of point id to leftmost imcoming halfedge id
    # Useful for retrieval of adhoc voronoi regions.
    d_pointToLeftmostHalfedgeIndex: Table[uint32, int32]


func extentWidth*[T](d: Delaunator[T]): T =
  ## Width of the *triangulation*.
  return d.maxX - d.minX


func extentHeight*[T](d: Delaunator[T]): T =
  ## Height of the *triangulation*.
  return d.maxY - d.minY


func boundWidth*[T](d: Delaunator[T]): T =
  ## Width of defined *bounds*.
  return d.bounds.maxX - d.bounds.minX


func boundHeight*[T](d: Delaunator[T]): T =
  ## Height of defined *bounds*.
  return d.bounds.maxY - d.bounds.minY


func hullNext*(d: Delaunator, sid: uint32): uint32 =
  ## Returns the **id** of the next *site* of the hull following the site defined by `sid`.
  d.d_hullNext[sid]


func hullPrev*(d: Delaunator, sid: uint32): uint32 =
  ## Returns the **id** of the previous *site* of the hull preceding the site defined by `sid`.
  d.d_hullPrev[sid]


func siteToLeftmostHalfedge*(d: Delaunator, sid: uint32): int32 =
  ## Returns the **id** of the 'leftmost' incomming *halfedge* to the site defined by
  ## `sid`. 'Leftmost' can be understood as if one were standing at the site's
  ## position. Used for constructing Voronoi edges / regions.
  return d.d_pointToLeftmostHalfedgeIndex[sid]


proc swap(arr: var seq[uint32]; i, j: int) {.inline.} =
  let tmp = arr[i]
  arr[i] = arr[j]
  arr[j] = tmp


# monotonically increases with real angle, but doesn't need expensive trigonometry
func pseudoAngle[F](dx, dy: F): F {.inline.} =
  let p = dx / (dx.abs + dy.abs)
  if dy > 0.0:
    result = (3.0 - p) / 4.0
  else:
    result = (1.0 + p) / 4.0


func dist[F](ax, ay, bx, by: F): F {.inline.} =
  let
    dx = ax - bx
    dy = ay - by
  result = dx * dx + dy * dy


func inCircle[F](ax, ay, bx, by, cx, cy, px, py: F): bool {.inline.} =
  let
    dx = ax - px
    dy = ay - py
    ex = bx - px
    ey = by - py
    fx = cx - px
    fy = cy - py

    ap = dx * dx + dy * dy
    bp = ex * ex + ey * ey
    cp = fx * fx + fy * fy

  result = dx * (ey * cp - bp * fy) -
           dy * (ex * cp - bp * fx) +
           ap * (ex * fy - ey * fx) < 0


func circumradius[F](ax, ay, bx, by, cx, cy: F): F {.inline.} =
  let
    dx = bx - ax
    dy = by - ay
    ex = cx - ax
    ey = cy - ay

    bl = dx * dx + dy * dy
    cl = ex * ex + ey * ey
    d = 0.5 / (dx * ey - dy * ex)

    x = (ey * bl - dy * cl) * d
    y = (dx * cl - ex * bl) * d

  result = x * x + y * y


# exported for use in helpers.
func circumcenter*[F](ax, ay, bx, by, cx, cy: F): tuple[x, y: F] {.inline.} =
  let
    dx = bx - ax
    dy = by - ay
    ex = cx - ax
    ey = cy - ay

    bl = dx * dx + dy * dy
    cl = ex * ex + ey * ey
    d = 0.5 / (dx * ey - dy * ex)

    x: F = ax + (ey * bl - dy * cl) * d
    y: F = ay + (dx * cl - ex * bl) * d

  result = (x, y)


proc quicksort[F](ids: var seq[uint32]; dists: seq[F]; left, right: int) =
  if (right - left <= 20):
    var i = left + 1
    while i <= right:
      let
        temp = ids[i]
        tempDist = dists[temp]
      var j = i - 1
      while j >= left and dists[ids[j]] > tempDist:
        ids[j + 1] = ids[j]
        dec j
      ids[j + 1] = temp
      inc i
  else:
    let median = ashr(left + right, 1)
    var
      i = left + 1
      j = right
    swap(ids, median, i)
    if dists[ids[left]] > dists[ids[right]]: swap(ids, left, right)
    if dists[ids[i]] > dists[ids[right]]: swap(ids, i, right)
    if dists[ids[left]] > dists[ids[i]]: swap(ids, left, i)

    let
      temp = ids[i]
      tempDist = dists[temp]
    while true:
      while true:
        inc i
        if not (dists[ids[i]] < tempDist): break
      while true:
        dec j
        if not (dists[ids[j]] > tempDist): break
      if j < i: break
      swap(ids, i, j)
    ids[left + 1] = ids[j]
    ids[j] = temp

    if right - i + 1 >= j - left:
      quicksort(ids, dists, i, right)
      quicksort(ids, dists, left, j - 1)
    else:
      quicksort(ids, dists, left, j - 1)
      quicksort(ids, dists, i, right)


proc update*[T](this: var Delaunator) =
  ## Builds and rebuilds the dual-graph. This procedure should be called on a
  ## *Delaunator* object after changing the object's `coords`.

  # Inner procs passed var 'this' param as 'uthis' due to the need to mutate it.
  # Simply closing over it results in 'cannot be captured / memory safety error'.

  proc u_link(uthis: var Delaunator; a, b: int32) {.inline.} =
    uthis.d_halfedges[a] = b
    if b != -1: uthis.d_halfedges[b] = a


  proc u_legalize(uthis: var Delaunator; a: var int32): uint32 =
    var
      i = 0
      ar = 0'i32

    while true:
      let b = uthis.d_halfedges[a]

      #[
      if the pair of triangles doesn't satisfy the Delaunay condition
      (p1 is inside the circumcircle of [p0, pl, pr]), flip them,
      then do the same check/flip recursively for the new pair of triangles

              pl                    pl
             /||\                  /  \
          al/ || \bl            al/    \a
           /  ||  \              /      \
          /  a||b  \    flip    /___ar___\
        p0\   ||   /p1   =>   p0\---bl---/p1
           \  ||  /              \      /
          ar\ || /br             b\    /br
             \||/                  \  /
              pr                    pr

      ]#

      let a0 = a - (a mod 3)
      ar = a0 + ((a + 2) mod 3)

      if b == -1: # convex hull edge
        if i == 0: break
        dec i
        a = int32(EDGE_STACK[i])
        continue

      let
        b0 = b - (b mod 3)
        al = a0 + ((a + 1) mod 3)
        bl = b0 + ((b + 2) mod 3)

        p0 = uthis.d_triangles[ar]
        pr = uthis.d_triangles[a]
        pl = uthis.d_triangles[al]
        p1 = uthis.d_triangles[bl]

        illegal = inCircle(
          uthis.coords[2 * p0], uthis.coords[2 * p0 + 1],
          uthis.coords[2 * pr], uthis.coords[2 * pr + 1],
          uthis.coords[2 * pl], uthis.coords[2 * pl + 1],
          uthis.coords[2 * p1], uthis.coords[2 * p1 + 1])

      if illegal:
        uthis.d_triangles[a] = p1
        uthis.d_triangles[b] = p0

        let hbl = uthis.d_halfedges[bl]

        # edge swapped on the other side of the hull (rare);
        if hbl == -1:
          var e = uthis.d_hullStart
          while true:
            if int32(uthis.d_hullTri[e]) == bl:
              uthis.d_hullTri[e] = uint32(a)
              break
            e = int32(uthis.d_hullPrev[e])
            if e == uthis.d_hullStart: break
        u_link(uthis, a, hbl)
        u_link(uthis, b, uthis.d_halfedges[ar])
        u_link(uthis, ar, bl)

        let br = b0 + ((b + 1) mod 3)

        # don't worry about hitting the cap: it can only happen on extremely degenerate input
        if i < EDGE_STACK.len:
          EDGE_STACK[i] = uint32(br)
          inc i

      else:
        if i == 0: break
        dec i
        a = int32(EDGE_STACK[i])

    return uint32(ar)


  proc u_addTriangle(uthis: var Delaunator; i0, i1, i2, a, b, c: int): int32 {.inline.} =
    let t = uthis.trianglesLen

    uthis.d_triangles[t] = uint32(i0)
    uthis.d_triangles[t + 1] = uint32(i1)
    uthis.d_triangles[t + 2] = uint32(i2)

    u_link(uthis, t, int32(a))
    u_link(uthis, t + 1, int32(b))
    u_link(uthis, t + 2, int32(c))

    uthis.trianglesLen += 3

    return t


  # The main update code begins here (nested procs mostly above)
  # Prepare to be (re)updated.
  let
    n = ashr(this.coords.len, 1) # n points
    maxTriangles = max(2 * n - 5, 0)
  this.trianglesLen = 0
  this.d_triangles = newSeq[uint32](maxTriangles * 3)
  this.d_halfedges = newSeq[int32](maxTriangles * 3)
  this.d_hashSize = ceil(sqrt(n.toFloat)).toInt
  this.d_hullStart = 0
  this.d_hullPrev = newSeq[uint32](n)
  this.d_hullNext = newSeq[uint32](n)
  this.d_hullTri = newSeq[uint32](n)
  this.d_hullHash = newSeq[int32](this.d_hashSize)
  this.d_ids = newSeq[uint32](n)
  this.d_dists = newSeq[T](n)

  # populate an array of point indices; calculate input data bbox
  this.minX = Inf
  this.minY = Inf
  this.maxX = NegInf
  this.maxY = NegInf

  for i in 0 ..< n:
    let
      x = this.coords[2 * i]
      y = this.coords[2 * i + 1]
    if x < this.minX: this.minX = x
    if y < this.minY: this.minY = y
    if x > this.maxX: this.maxX = x
    if y > this.maxY: this.maxY = y
    this.d_ids[i] = uint32(i)
  let
    cx = (this.minX + this.maxX) / 2
    cy = (this.minY + this.maxY) / 2

  # default clipping bounds
  this.bounds = (this.minX, this.minY, this.maxX, this.maxY)

  var
    i0, i1, i2: int
    i0x, i0y, i1x, i1y, i2x, i2y = T(0) # Temp init to something for case of empty coords.

  # pick a seed point close to the center
  var minDist = Inf
  for i in 0 ..< n:
    let d = dist(cx, cy, this.coords[2 * i], this.coords[2 * i + 1])
    if d < minDist:
      i0 = i
      minDist = d

  if this.coords.len > 0:
    i0x = this.coords[2 * i0]
    i0y = this.coords[2 * i0 + 1]

  # find the point closest to the seed
  minDist = Inf
  for i in 0 ..< n:
    if i == i0: continue
    let d = dist(i0x, i0y, this.coords[2 * i], this.coords[2 * i + 1])
    if d < minDist and d > 0:
      i1 = i
      minDist = d

  if this.coords.len > 0:
    i1x = this.coords[2 * i1]
    i1y = this.coords[2 * i1 + 1]

  var minRadius = Inf

  # find the third point which forms the smallest circumcircle with the first two
  for i in 0 ..< n:
    if i == i0 or i == i1: continue
    let r = circumradius(i0x, i0y, i1x, i1y, this.coords[2 * i], this.coords[2 * i + 1])
    if r < minRadius:
      i2 = i
      minRadius = r

  if this.coords.len > 0:
    i2x = this.coords[2 * i2]
    i2y = this.coords[2 * i2 + 1]

  if minRadius == Inf:
    # order collinear points by dx (or dy if all x are identical)
    # and return the list as a hull
    for i in 0 ..< n:
      let
        xcrd = this.coords[2 * i] - this.coords[0]
        ycrd = this.coords[2 * i + 1] - this.coords[1]
      if xcrd != 0:
        this.d_dists[i] = xcrd
      else:
        this.d_dists[i] = ycrd
    quicksort(this.d_ids, this.d_dists, 0, n - 1)
    var hull = newSeq[uint32](n)
    var
      j = 0
      d0 = NegInf
    for i in 0 ..< n:
      let
        id = this.d_ids[i]
        d = this.d_dists[id]
      if d > d0:
        hull[j] = uint32(id)
        inc j
        d0 = d
    this.hull = hull[0 ..< j]
    this.triangles = newSeqOfCap[uint32](0)
    this.halfedges = newSeqOfCap[int32](0)
    return

  # swap the order of the seed points for counter-clockwise orientation
  if orient2d(i0x, i0y, i1x, i1y, i2x, i2y) < 0:
    let
      i = i1
      x = i1x
      y = i1y
    i1 = i2
    i1x = i2x
    i1y = i2y
    i2 = i
    i2x = x
    i2y = y

  let
    (u_cx, u_cy) = circumcenter[T](i0x, i0y, i1x, i1y, i2x, i2y)

  # defined here to close over u_cx, u_cy
  proc u_hashKey(uthis: var Delaunator; x, y: SomeFloat): int32 =
    return int32(floor(pseudoAngle(x - u_cx, y - u_cy) * float(uthis.d_hashSize)) mod float(uthis.d_hashSize))

  for i in 0 ..< n:
    this.d_dists[i] = dist(this.coords[2 * i], this.coords[2 * i + 1], u_cx, u_cy)

  # sort the points by distance from the seed triangle circumcenter
  quicksort(this.d_ids, this.d_dists, 0, n - 1)

  # set up the seed triangle as the starting hull
  this.d_hullStart = i0
  var hullSize = 3

  this.d_hullNext[i0] = uint32(i1); this.d_hullPrev[i2] = uint32(i1)
  this.d_hullNext[i1] = uint32(i2); this.d_hullPrev[i0] = uint32(i2)
  this.d_hullNext[i2] = uint32(i0); this.d_hullPrev[i1] = uint32(i0)

  this.d_hullTri[i0] = 0
  this.d_hullTri[i1] = 1
  this.d_hullTri[i2] = 2

  this.d_hullHash.fill(-1)
  this.d_hullHash[u_hashKey(this, i0x, i0y)] = int32(i0)
  this.d_hullHash[u_hashKey(this, i1x, i1y)] = int32(i1)
  this.d_hullHash[u_hashKey(this, i2x, i2y)] = int32(i2)

  #this.trianglesLen = 0 # already init'd in fromCoords
  discard u_addTriangle(this, i0, i1, i2, -1, -1, -1)

  var
    xp, yp = this.coords[0] # just so xp & yp are of correct type
  for k in 0 ..< this.d_ids.len:
    let
      i = this.d_ids[k]
      x = this.coords[2 * i]
      y = this.coords[2 * i + 1]

    # skip near-duplicate points
    if k > 0 and abs(x - xp) <= epsilon(float64) and abs(y - yp) <= epsilon(float64): continue
    xp = x
    yp = y

    # skip seed triangle points
    if i == uint32(i0) or i == uint32(i1) or i == uint(i2): continue

    # find a visible edge on the convex hull using edge hash
    var
      start = 0
      key = u_hashKey(this, x, y)
    for j in 0 ..< this.d_hashSize:
      start = this.d_hullHash[(key + j) mod this.d_hashSize]
      if start != -1 and uint32(start) != this.d_hullNext[start]: break

    start = int(this.d_hullPrev[start])
    var
      e = start
      q = int(this.d_hullNext[e])
    while orient2d(x, y, this.coords[2 * e], this.coords[2 * e + 1], this.coords[2 * q], this.coords[2 * q + 1]) >= 0:
      e = q
      if e == start:
        e = -1
        break
      q = int(this.d_hullNext[e])
    if e == -1: continue # likely a near-duplicate point; skip it

    # add the first triangle from the point
    var t = u_addTriangle(this, e, int(i), int(this.d_hullNext[e]), -1, -1, int(this.d_hullTri[e]))

    # recursively flip triangles from the point until they satisfy the Delaunay condition
    var tmp = t + 2 # use mutable tmp to make u_legalize happy
    this.d_hullTri[i] = u_legalize(this, tmp)
    this.d_hullTri[e] = uint32(t) # keep track of boundary triangles on the hull
    inc hullSize

    # walk forward through the hull, adding more triangles and flipping recursively
    var n = int(this.d_hullNext[e])
    q = int(this.d_hullNext[n])
    while orient2d(x, y, this.coords[2 * n], this.coords[2 * n + 1], this.coords[2 * q], this.coords[2 * q + 1]) < 0:
      t = u_addTriangle(this, n, int(i), q, int(this.d_hullTri[i]), -1, int(this.d_hullTri[n]))
      tmp = t + 2 # use mutable tmp to make u_legalize happy
      this.d_hullTri[i] = u_legalize(this, tmp)
      this.d_hullNext[n] = uint32(n) # mark as removed
      dec hullSize
      n = q
      q = int(this.d_hullNext[n])

    # walk backward from the other side, adding more triangles and flipping
    if e == start:
      q = int(this.d_hullPrev[e])
      while orient2d(x, y, this.coords[2 * q], this.coords[2 * q + 1], this.coords[2 * e], this.coords[2 * e + 1]) < 0:
        t = u_addTriangle(this, q, int(i), e, -1, int(this.d_hullTri[e]), int(this.d_hullTri[q]))
        tmp = t + 2 # use mutable tmp to make u_legalize happy
        discard u_legalize(this, tmp)
        this.d_hullTri[q] = uint32(t)
        this.d_hullNext[e] = uint32(e) # mark as removed
        dec hullSize
        e = q
        q = int(this.d_hullPrev[e])

    # update the hull indices
    this.d_hullPrev[i] = uint32(e)
    this.d_hullStart = e
    this.d_hullPrev[n] = uint32(i)
    this.d_hullNext[e] = uint32(i)
    this.d_hullNext[i] = uint32(n)

    # save the two new edges in the hash table
    this.d_hullHash[u_hashKey(this, x, y)] = int32(i)
    this.d_hullHash[u_hashKey(this, this.coords[2 * e], this.coords[2 * e + 1])] = int32(e)

  this.hull = newSeq[uint32](hullSize)
  var e = this.d_hullStart
  for i in 0 ..< hullSize:
    this.hull[i] = uint32(e)
    e = int(this.d_hullNext[e])

  # compute rays needed for infinate region clipping
  this.vectors = newSeq[T](this.coords.len * 2)
  var
    h = this.hull[^1]
    p0, p1 = h * 4
    x0, x1 = this.coords[2 * h]
    y0, y1 = this.coords[2 * h + 1]
  for i in 0 ..< this.hull.len:
    h = this.hull[i]
    p0 = p1
    x0 = x1
    y0 = y1
    p1 = h * 4
    x1 = this.coords[2 * h]
    y1 = this.coords[2 * h + 1]
    let
      yDlta = y0 - y1
      xDlta = x1 - x0
    this.vectors[p1] = yDlta
    this.vectors[p0 + 2] = yDlta
    this.vectors[p1 + 1] = xDlta
    this.vectors[p0 + 3] = xDlta

  # Build the index of point id to leftmost incoming halfedge
  clear(this.d_pointToLeftmostHalfedgeIndex)
  var he: int32 = 0
  while he < this.trianglesLen:
    let
      nextHE = if he mod 3 == 2: he - 2 else: he + 1
      endpoint = this.d_triangles[nextHE]
    if (not hasKey(this.d_pointToLeftmostHalfedgeIndex, endpoint)) or this.d_halfedges[he] == -1:
      this.d_pointToLeftmostHalfedgeIndex[endpoint] = he
    inc he

  # trim typed triangle mesh arrays
  this.triangles = this.d_triangles[0 ..< this.trianglesLen]
  this.halfedges = this.d_halfedges[0 ..< this.trianglesLen]


proc fromCoords*[T:SomeFloat](coordinates: var seq[T]): Delaunator[T] =
  ## Returns a *Delaunator* object constructed from `coordinates`, a flattened
  ## sequence of points representing site locations.
  result = Delaunator[T](coords: coordinates)
  update[T](result)


func defaultGetX[P, T](p: P): T =
  ## Default getX proc for `fromPoints`. Coerces to `T`.
  T(p[0])


func defaultGetY[P, T](p: P): T =
  ## Default getY proc for `fromPoints`. Coerces to `T`.
  T(p[1])


#proc fromPoints*[P, T](points: seq[P]; getX: proc (p: P): T = defaultGetX; getY: proc (p: P): T = defaultGetY): Delaunator[T] =
proc fromPoints*[P, T](points: seq[P]): Delaunator[T] =
  ## Returns a *Delaunator* object constructed from `points`, a sequence of some
  ## pairwise type from which *x* and *y* coordinate values can be extracted via
  ## the '[]' operator. When x and y values are not at [0] and [1] respectively,
  ## use `fromCustom` instead.
  var
    coords = newSeq[T](points.len * 2)
  for i, point in points:
    coords[2 * i] = defaultGetX[P, T](point)
    coords[2 * i + 1] = defaultGetY[P, T](point)
  fromCoords[T](coords)


proc fromCustom*[P, T](points: seq[P]; getX, getY: proc (p: P): T): Delaunator[T] =
  ## Returns a *Delaunator* object constructed from `points`, a sequence of some
  ## type from which *x* and *y* coordinate values are extracted via the
  ## specified `getX` and `getY` procs.
  var
    coords = newSeq[T](points.len * 2)
  for i, point in points:
    coords[2 * i] = getX(point)
    coords[2 * i + 1] = getY(point)
  fromCoords[T](coords)
