---
name: odin-language-guide
description: "Use when you need to explain Odin, generate Odin code, or review Odin snippets using the repository's reference guide."
---

# Odin Language Guide

## Purpose

Use this skill to help an agent understand Odin, generate correct Odin code, and stay aligned with the repository's Odin reference guide.

## When to use

Use this skill when:

- you need to explain Odin syntax or semantics
- you need to generate or edit Odin code
- you need to review a generated Odin snippet for correctness
- you need to translate code from another language into Odin

## Bundled asset

- Reference guide: [references/odin-for-open-weight-models.md](references/odin-for-open-weight-models.md)

## Workflow

1. Read the bundled Odin reference guide. If the bundled reference guide does not cover the requested feature, state that explicitly and fall back to general Odin language knowledge, clearly noting the information is not from the reference guide.
2. Identify the request type:
   - explanation
   - code generation
   - code review
   - translation from another language
3. Apply Odin-specific conventions:
   - use `package main` for entry points
   - define procedures with `proc`
   - prefer explicit declarations
   - use `^` for pointers and `context` for allocator-aware code
   - avoid C-style assumptions and implicit garbage collection
   - check the reference guide's common mistakes before accepting generated syntax
4. Keep the response focused on the user's ask and include a minimal working example when helpful.
5. Validate the result:
   - the syntax is idiomatic Odin
   - imports and package names are reasonable
   - the example fits the language rules
   - the answer does not rely on unsupported C-style patterns

## Decision points

- If the user wants a quick explanation, provide a short summary and one illustrative example.
- If the user wants code generation, produce a minimal complete Odin example.
- If the user wants a review, point out incorrect syntax, non-idiomatic patterns, and likely compile issues.
- If the user asks for translation, preserve Odin semantics rather than mechanically converting from another language.

## Quality bar

- Prefer explicit, readable code.
- Mention the main Odin-specific distinction when relevant.
- When uncertain, refer to the bundled reference guide at references/odin-for-open-weight-models.md first, then the official Odin language documentation at https://odin-lang.org/docs/.
- Avoid claiming a snippet is correct without checking the language rules.

## Example prompts

- "Explain Odin's `proc` syntax to me."
- "Generate a small Odin program that reads a file and prints its contents."
- "Review this Odin snippet for mistakes."
- "Translate this C function to Odin."
