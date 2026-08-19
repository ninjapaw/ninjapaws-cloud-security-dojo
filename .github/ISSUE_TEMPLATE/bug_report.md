name: 🐛 Bug Report
description: Report a bug in the Ninja Paws Cloud Security Dojo
title: "[BUG] "
labels: ["bug"]

body:
  - type: markdown
    attributes:
      value: |
        Thank you for reporting a bug! Please provide as much detail as possible.
        
        **Important:** For security issues, see [SECURITY.md](SECURITY.md)

  - type: textarea
    id: description
    attributes:
      label: Description
      description: Clear description of the bug
      placeholder: What happened?
    validations:
      required: true

  - type: textarea
    id: reproduction
    attributes:
      label: Steps to Reproduce
      description: How can we reproduce the issue?
      placeholder: |
        1. Run `./scripts/compose.sh up`
        2. Navigate to `http://localhost:8080`
        3. ...
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: Expected Behavior
      description: What should happen?
      placeholder: The application should...
    validations:
      required: true

  - type: textarea
    id: actual
    attributes:
      label: Actual Behavior
      description: What actually happened?
      placeholder: Instead, it...
    validations:
      required: true

  - type: textarea
    id: environment
    attributes:
      label: Environment
      description: Your environment details
      placeholder: |
        - OS: [e.g., Ubuntu 24.04, macOS 13.0]
        - Docker version: [output of `docker --version`]
        - Node version: [output of `node --version`]
        - Browser: [if applicable]
    validations:
      required: true

  - type: textarea
    id: logs
    attributes:
      label: Logs and Error Messages
      description: Relevant logs, error messages, stack traces
      placeholder: Paste logs here
      render: bash

  - type: textarea
    id: context
    attributes:
      label: Additional Context
      description: Any other relevant information
      placeholder: Screenshots, configurations, etc.

  - type: checkboxes
    id: checklist
    attributes:
      label: Checklist
      options:
        - label: I've searched for existing issues
          required: true
        - label: This is not a security issue (see SECURITY.md)
          required: true
        - label: I've provided clear reproduction steps
          required: true
