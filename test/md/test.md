---
title: "ZSSG test"
stylesheet: "style.css" - inline
stylesheet: "https://fonts.googleapis.com/css2?family=Roboto"
js: "script.js" - inline
---

# ZSSG - Zig Static Site Generator

## Sub-Heading

### Sub-Sub-Heading

{#my-paragraph}
this is a paragraph with a custom id

## Unordered List

- list
- of
- items

## Ordered List

1. one item
2. two items
3. three items

```
const x: []const u8 = "hello";
std.debug.print("{s}, world!", .{x});
```

We can do **inline** formatting as well! Here's some _italics_ and a `code block` too!

We can even escape characters. 2 \* 2 = 4!

This is a test of a [link](https://google.com) to Google -- It will open in a new tab.
This is a test of a non-blank [link](https://google.com){noblank} to Google, it will open in this tab.

List of links:

- [link](https://google.com)
- [link in same tab](https://google.com){noblank}

> this is a blockquote, that extends on one line.

> This is a blockquote
> that spans multiple lines

| Tables | Are | Cool                  |
| ------ | --- | --------------------- |
| This   | Is  | A                     |
| Set    | Of  | Table                 |
| Rows   | And | Columns {#table-cell} |

This is a nested list

- Item 1
  - Subitem 1.1
  - Subitem 1.2
  - Subitem 1.3
    1. Subitem 1.3.1
    2. Subitem 1.3.2
- Item 2

Image of the Zig logo
![zig logo](https://ziglang.org/zig-logo-light.svg)

<div class="myclass">
    <span class="span"> Custom HTML </span>
</div>
