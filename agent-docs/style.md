# Coding Style Guide

Module organization

- Require Roblox services first, then local modules, then declare the module table.
- Keep helpers local and expose a small public API at the bottom of a module.
- Keep type declarations close to the data they describe.

Naming

- Use PascalCase for Instances, modules, and public functions.
- Use camelCase for locals, helper functions, and object/record data properties.
- Name boolean data properties as questions or capabilities, for example isHeld, usesClips, and autoFire.

Typing and compilation

- Use --!strict in every module.
- Type function parameters, return values, and all non-scalar objects.
- Scalar values declared and used in the same scope do not require explicit annotations.
- Use --!native when a script performs heavy Luau computation with little Roblox API usage.

Input and validation

- Treat developer-authored internal contracts differently from untrusted runtime input.
- Use assert for programmer/developer contract violations when failure indicates incorrect code or invalid trusted setup.
- For client/network-controlled or otherwise untrusted runtime data, validate and reject safely with early returns rather than assertions.
- Do not add defensive validation for trusted static configuration merely to make every misuse recoverable. Poor developer configuration may fail naturally at the code path that consumes it.
- Avoid excessive validation that duplicates guarantees already provided by trusted code paths.

Project rule: assert is for trusted developer/programmer contract violations. Client/network-controlled values are untrusted runtime data and must be validated and rejected safely rather than asserted.

Control flow and readability

- Prefer early returns to keep successful paths shallow.
- Use generalized iteration instead of ipairs or pairs. Existing ipairs/pairs loops may be safely replaced with generalized iteration whenever that code is touched; a standalone project-wide cleanup is not required.
- Avoid unnecessary nesting when an early return makes the control flow clearer.
- Avoid long if/elseif chains when explicit dispatch, data-driven configuration, or another clear representation better defines behavior.
- Do not mechanically eliminate short, readable conditionals just to satisfy these preferences.

Performance and lifetime

- Cache repeated expensive lookups in hot paths when the cache lifetime and invalidation behavior are clear. This is the current project-wide rule; add narrower mandatory caching cases later if recurring patterns justify them.
- During unload/stop, disconnect connections and clear pooled tables.
- Guard delayed or repeating work with both a generation value and enabled state.

Comments

- Use comments for authority, lifetime, performance constraints, non-obvious intent, or other information the code itself does not make clear.
- Do not restate straightforward code in comments.
