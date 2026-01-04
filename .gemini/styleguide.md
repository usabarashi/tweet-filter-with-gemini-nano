# Gemini Code Assist Code Review Style Guide

## Review Focus Areas

### 1. Security
- Identify potential security vulnerabilities (XSS, injection attacks, etc.)
- Check for secure handling of sensitive data
- Verify proper input validation and sanitization

### 2. Code Quality
- Assess code readability and maintainability
- Check adherence to functional and declarative programming paradigms
- Verify proper use of immutable data structures
- Ensure minimal side effects

### 3. Architecture
- Check for proper separation of concerns
- Verify single responsibility principle
- Assess module coupling and cohesion

### 4. Performance
- Identify potential performance bottlenecks
- Check for unnecessary computations or redundant operations
- Verify efficient use of browser APIs and resources

### 5. Correctness
- Verify logical correctness of implementations
- Check for edge cases and error handling
- Ensure proper type safety (TypeScript)

### 6. Best Practices
- Check for unused code or dead code paths
- Verify proper error handling patterns
- Assess test coverage and test quality
- Review documentation completeness

## Specific Guidelines

### TypeScript/JavaScript
- Prefer functional patterns over imperative code
- Use const by default, let only when reassignment is necessary
- Avoid any type, prefer proper type definitions
- Use async/await over promise chains for better readability

### Chrome Extension Development
- Verify proper use of Chrome APIs
- Check manifest.json permissions for minimal necessary access
- Ensure content scripts and background scripts are properly isolated

### Testing
- Verify unit tests cover critical functionality
- Check for proper mocking and test isolation
- Ensure tests are readable and maintainable

## Review Tone
- Be constructive and educational
- Explain the reasoning behind suggestions
- Provide examples when suggesting alternatives
- Prioritize high-severity issues over stylistic preferences
