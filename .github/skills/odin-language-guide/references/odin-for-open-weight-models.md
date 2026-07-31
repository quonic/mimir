# Odin for Open-Weight Models

This guide is a compact reference for helping language models understand and use the Odin programming language effectively. It is grounded in the official Odin documentation and intended for code generation, code review, and prompt-driven editing.

## 1. What Odin is

Odin is a systems-oriented language with a simple, explicit syntax and strong support for low-level programming. It emphasizes:

- explicit declarations
- predictable control flow
- manual memory management with allocators and context
- straightforward interop with C and other foreign code
- data-oriented and performance-conscious design

## 2. Core syntax patterns

### Hello world

```odin
package main

import "core:fmt"

main :: proc() {
    fmt.println("Hellope!")
}
```

### Key syntax notes

- `package main` declares the package.
- `import "core:fmt"` imports a package.
- `main :: proc()` defines the entry point.
- `proc` is Odin’s equivalent of a function.
- `::` is used for declarations and aliases.
- `:=` declares and infers a value.
- `=` assigns to an existing variable.

## 3. Declarations and variables

### Variables

```odin
x: int = 123
x = 637

y := 1
z, w := 2, "hello"
```

### Constants

```odin
PI :: 3.14159
name :: "Odin"
```

Constants are compile-time values and must be evaluable at compile time.

## 4. Basic types

Common built-in types include:

```odin
bool
int, i8, i16, i32, i64, i128
uint, u8, u16, u32, u64, u128, uintptr
f32, f64
string
cstring
rawptr
rune
```

### Notes

- Use `int` for general integer work unless a specific width is needed.
- `string` is a UTF-8 string type.
- `cstring` is for C interop.
- `rune` represents a Unicode code point.

## 5. Procedures

Procedures are defined with `proc`.

```odin
multiply :: proc(x, y: int) -> int {
    return x * y
}
```

### Multiple return values

```odin
swap :: proc(x, y: int) -> (int, int) {
    return y, x
}

a, b := swap(1, 2)
```

### Named return values

```odin
sum_and_diff :: proc(a, b: int) -> (sum: int, diff: int) {
    sum = a + b
    diff = a - b
    return
}
```

## 6. Control flow

### If statements

```odin
if x >= 0 {
    fmt.println("positive")
}
```

### For loops

```odin
for i := 0; i < 10; i += 1 {
    fmt.println(i)
}
```

### Range-based for loops

```odin
for i in 0..<10 {
    fmt.println(i)
}
```

### Switch

```odin
switch value {
case 0:
    fmt.println("zero")
case 1:
    fmt.println("one")
case:
    fmt.println("other")
}
```

## 7. Arrays, slices, and dynamic arrays

### Fixed arrays

```odin
arr: [3]int = {1, 2, 3}
```

### Slices

```odin
s := []int{1, 2, 3}
```

### Dynamic arrays

```odin
values: [dynamic]int
append(&values, 1, 2, 3)
```

### Common helpers

- `len(x)` gets length
- `cap(x)` gets capacity for dynamic arrays
- `append(&arr, ...)` adds elements
- `delete(x)` cleans up allocated data structures

## 8. Structs, enums, and unions

### Structs

```odin
Vector2 :: struct {
    x: f32,
    y: f32,
}

v := Vector2{1, 2}
v.x = 4
```

### Enums

```odin
Direction :: enum {
    North,
    East,
    South,
    West,
}
```

### Unions

```odin
Value :: union {
    int,
    string,
}
```

## 9. Pointers and references

Odin uses `^T` for pointers.

```odin
x := 123
p := &x
fmt.println(p^)
p^ = 456
```

Important differences from C:

- Odin uses `^` instead of `*` for pointer syntax.
- There is no pointer arithmetic by default.
- Use `ptr_offset` or related helpers when needed.

## 10. Memory and context

Odin has an implicit `context` system used by allocators and core libraries.

```odin
ptr := new(int)
free(ptr)
```

Models should not assume garbage collection. Odin is usually explicit about allocation and cleanup.

## 11. Import and package conventions

- Packages are directory-based.
- The entry point is usually in a package named `main`.
- Core standard library imports commonly use `core:` prefixes, such as:
  - `import "core:fmt"`
  - `import "core:os"`
  - `import "core:strings"`

## 12. Build and run

From the project root:

```bash
odin run .
```

Or for a single file:

```bash
odin run file.odin -file
```

## 13. Common model mistakes to avoid

- Do not write C-style function syntax like `int foo()`. Use `proc`.
- Do not use `*` for pointer types; use `^`.
- Do not assume `return` syntax matches other languages; Odin uses `return` and supports multiple results.
- Do not assume automatic memory management; use explicit allocation patterns when needed.
- Prefer explicit declarations over overly clever abstractions.

## 14. Recommended generation pattern for models

When generating Odin code, prefer this shape:

```odin
package main

import "core:fmt"

main :: proc() {
    fmt.println("example")
}
```

For small utilities, keep the code explicit, use `proc`, and favor simple data structures before advanced metaprogramming.

## 15. Useful references

- Official language overview: <https://odin-lang.org/docs/overview/>
- Installation guide: <https://odin-lang.org/docs/install/>
- Package docs: <https://pkg.odin-lang.org/>
- GitHub repository: <https://github.com/odin-lang/Odin>
