// Splay tree benchmark, adapted from the Octane 2.0 / V8 benchmark suite.
//
// Original: Copyright 2009 the V8 project authors, BSD-style license.
// This is a self-contained ES2017 port for the clun engine. It exercises
// allocation, GC pressure, and property access by repeatedly inserting,
// finding, and removing nodes in a self-balancing splay tree whose payloads
// are freshly allocated objects and arrays.
//
// Output contract: exactly one line on success:
//   BENCH splay <total_ms> <iterations>

'use strict';

// Number of timed iterations of the core workload. Tuned small for a slow
// tree-walking interpreter; the human is expected to tune this upward.
const ITERATIONS = 40;

// Size of the resident tree maintained across the workload. Scaled down from
// Octane's 8000 to fit a tree-walking interpreter's heap while preserving the
// splay-tree structure and access patterns.
const kSplayTreeSize = 130;
// Number of nodes to churn (remove + re-insert) per workload step.
const kSplayTreeModifications = 15;
// Payload depth: how deeply nested the allocated payload objects are.
const kSplayTreePayloadDepth = 3;

// ---------------------------------------------------------------------------
// Seeded PRNG (linear congruential generator). This replaces Math.random so
// the key-insertion order — and therefore the whole workload — is identical
// on every run. Constants are the classic MINSTD / Park-Miller variant.
// ---------------------------------------------------------------------------
function Random(seed) {
  this.seed = seed >>> 0;
}
// Returns a float in [0, 1). Uses the 31-bit LCG defined by:
//   seed = (seed * 1103515245 + 12345) mod 2^31
Random.prototype.next = function () {
  // Keep arithmetic within safe-integer range: 1103515245 * (2^31-1) < 2^62.
  this.seed = (this.seed * 1103515245 + 12345) % 2147483648;
  return this.seed / 2147483648;
};

// ---------------------------------------------------------------------------
// Payload generation. Produces nested objects/arrays to create realistic
// allocation and GC pressure. Deterministic given the same key.
// ---------------------------------------------------------------------------
function generatePayloadTree(depth, tag) {
  if (depth === 0) {
    return {
      array: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
      string: 'String for key ' + tag + ' in leaf node'
    };
  }
  return {
    left: generatePayloadTree(depth - 1, tag),
    right: generatePayloadTree(depth - 1, tag)
  };
}

// ---------------------------------------------------------------------------
// SplayTree node.
// ---------------------------------------------------------------------------
function SplayTreeNode(key, value) {
  this.key = key;
  this.value = value;
  this.left = null;
  this.right = null;
}

// Performs an ordered traversal of the subtree starting at this node.
SplayTreeNode.prototype.traverse = function (f) {
  var current = this;
  while (current) {
    var left = current.left;
    if (left) left.traverse(f);
    f(current);
    current = current.right;
  }
};

// ---------------------------------------------------------------------------
// SplayTree: a self-balancing binary search tree. Splaying moves an accessed
// node to the root, which keeps frequently accessed keys near the top.
// ---------------------------------------------------------------------------
function SplayTree() {
  this.root_ = null;
}

SplayTree.prototype.isEmpty = function () {
  return !this.root_;
};

// Inserts a node into the tree with the given key and value. If the key is
// already present, the value is replaced.
SplayTree.prototype.insert = function (key, value) {
  if (this.isEmpty()) {
    this.root_ = new SplayTreeNode(key, value);
    return;
  }
  // Splay on the key to move the closest node to the root.
  this.splay_(key);
  if (this.root_.key === key) {
    return;
  }
  var node = new SplayTreeNode(key, value);
  if (key > this.root_.key) {
    node.left = this.root_;
    node.right = this.root_.right;
    this.root_.right = null;
  } else {
    node.right = this.root_;
    node.left = this.root_.left;
    this.root_.left = null;
  }
  this.root_ = node;
};

// Removes a node with the specified key from the tree. Throws if not found.
SplayTree.prototype.remove = function (key) {
  if (this.isEmpty()) {
    throw new Error('Key not found: ' + key);
  }
  this.splay_(key);
  if (this.root_.key !== key) {
    throw new Error('Key not found: ' + key);
  }
  var removed = this.root_;
  if (!this.root_.left) {
    this.root_ = this.root_.right;
  } else {
    var right = this.root_.right;
    this.root_ = this.root_.left;
    // Splay to make the largest node in the left subtree the new root.
    this.splay_(key);
    this.root_.right = right;
  }
  return removed;
};

// Returns the node with the given key, or null if not present.
SplayTree.prototype.find = function (key) {
  if (this.isEmpty()) return null;
  this.splay_(key);
  return this.root_.key === key ? this.root_ : null;
};

// Returns the node with the largest key value.
SplayTree.prototype.findMax = function (opt_startNode) {
  if (this.isEmpty()) return null;
  var current = opt_startNode || this.root_;
  while (current.right) current = current.right;
  return current;
};

// Returns a list, in order, of all the keys currently in the tree.
SplayTree.prototype.exportKeys = function () {
  var result = [];
  if (!this.isEmpty()) {
    this.root_.traverse(function (node) {
      result.push(node.key);
    });
  }
  return result;
};

// Perform the splay operation for the given key. Moves the node with the
// given key (or the last node on the search path) to the root.
SplayTree.prototype.splay_ = function (key) {
  if (this.isEmpty()) return;
  // Scratch node whose left/right children become the two spines.
  var dummy = new SplayTreeNode(null, null);
  var left = dummy;
  var right = dummy;
  var current = this.root_;
  while (true) {
    if (key < current.key) {
      if (!current.left) break;
      if (key < current.left.key) {
        // Rotate right.
        var tmp = current.left;
        current.left = tmp.right;
        tmp.right = current;
        current = tmp;
        if (!current.left) break;
      }
      // Link right.
      right.left = current;
      right = current;
      current = current.left;
    } else if (key > current.key) {
      if (!current.right) break;
      if (key > current.right.key) {
        // Rotate left.
        var tmp2 = current.right;
        current.right = tmp2.left;
        tmp2.left = current;
        current = tmp2;
        if (!current.right) break;
      }
      // Link left.
      left.right = current;
      left = current;
      current = current.right;
    } else {
      break;
    }
  }
  // Assemble.
  left.right = current.left;
  right.left = current.right;
  current.left = dummy.right;
  current.right = dummy.left;
  this.root_ = current;
};

// ---------------------------------------------------------------------------
// Workload setup / step.
// ---------------------------------------------------------------------------

// Insert a fresh random key not already present, returning that key.
function insertNewNode(tree, rng) {
  var key;
  do {
    key = rng.next();
  } while (tree.find(key) !== null);
  var payload = generatePayloadTree(kSplayTreePayloadDepth, String(key));
  tree.insert(key, payload);
  return key;
}

// Build a tree of kSplayTreeSize nodes. Returns { tree, rng }.
function splaySetup(rng) {
  var tree = new SplayTree();
  for (var i = 0; i < kSplayTreeSize; i++) {
    insertNewNode(tree, rng);
  }
  return tree;
}

// One workload step: churn kSplayTreeModifications nodes (remove the largest,
// then insert a new random node), keeping the tree size roughly constant.
function splayStep(tree, rng) {
  for (var i = 0; i < kSplayTreeModifications; i++) {
    var key = insertNewNode(tree, rng);
    var greatest = tree.findMax();
    if (greatest === null) {
      tree.remove(key);
    } else {
      tree.remove(greatest.key);
    }
  }
}

// ---------------------------------------------------------------------------
// Correctness check. Verifies the tree is non-empty, structurally ordered
// (keys strictly increasing), retains the intended size, and that find()
// returns the exact payload previously inserted for a sampled key. Throws on
// any failure so a broken port fails loudly instead of mis-measuring.
// ---------------------------------------------------------------------------
function verify(tree) {
  if (tree.isEmpty()) {
    throw new Error('splay: verification failed — tree is empty');
  }
  var keys = tree.exportKeys();
  if (keys.length !== kSplayTreeSize) {
    throw new Error(
      'splay: verification failed — expected ' + kSplayTreeSize +
      ' keys, found ' + keys.length);
  }
  for (var i = 0; i < keys.length - 1; i++) {
    if (keys[i] >= keys[i + 1]) {
      throw new Error(
        'splay: verification failed — keys not strictly ordered at index ' + i);
    }
  }
  // Insert a sentinel key with a known payload, then look it up and confirm
  // the exact object identity and value come back through find().
  var sentinelKey = 0.5;
  var sentinelPayload = generatePayloadTree(kSplayTreePayloadDepth, 'SENTINEL');
  tree.insert(sentinelKey, sentinelPayload);
  var found = tree.find(sentinelKey);
  if (found === null || found.key !== sentinelKey) {
    throw new Error('splay: verification failed — sentinel key not found');
  }
  if (found.value !== sentinelPayload) {
    throw new Error(
      'splay: verification failed — sentinel payload identity mismatch');
  }
  // Confirm the nested payload structure is intact and property access works.
  // Walk down kSplayTreePayloadDepth left-links to reach a leaf node.
  var leaf = found.value;
  for (var d = 0; d < kSplayTreePayloadDepth; d++) {
    leaf = leaf.left;
  }
  if (!leaf || leaf.array.length !== 10 || leaf.array[9] !== 9) {
    throw new Error(
      'splay: verification failed — sentinel payload structure corrupted');
  }
  tree.remove(sentinelKey);
}

// ---------------------------------------------------------------------------
// Runner.
// ---------------------------------------------------------------------------
// Number of churn steps per iteration.
const kStepsPerIteration = 8;

function runOnce() {
  var rng = new Random(49734321);
  var tree = splaySetup(rng);
  for (var i = 0; i < kStepsPerIteration; i++) {
    splayStep(tree, rng);
  }
  verify(tree);
}

// One untimed warmup iteration to prime caches / JIT-equivalent state.
runOnce();

// Clun.nanoseconds() is a monotonic ns clock; Date.now() is only 1-second-granular here.
var start = Clun.nanoseconds();
for (var it = 0; it < ITERATIONS; it++) {
  runOnce();
}
var totalMs = (Clun.nanoseconds() - start) / 1e6;

console.log('BENCH splay ' + totalMs.toFixed(1) + ' ' + ITERATIONS);
