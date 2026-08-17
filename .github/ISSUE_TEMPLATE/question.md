name: ❓ Question or Discussion
description: Ask a question about the Ninja Paws Cloud Security Dojo
title: "[QUESTION] "
labels: ["question"]

body:
  - type: markdown
    attributes:
      value: |
        Have a question? We're here to help!
        
        💡 **Tip:** Check the [README](README.md) and [security policy](../../SECURITY.md) first.
        
        For discussions, you might prefer using [GitHub Discussions](../../discussions).

  - type: textarea
    id: question
    attributes:
      label: Your Question
      description: What would you like to know?
      placeholder: I'm trying to...
    validations:
      required: true

  - type: textarea
    id: context
    attributes:
      label: Context
      description: What have you tried? What's your setup?
      placeholder: |
        Environment:
        - OS: ...
        - Tools: ...
        
        What I've tried:
        - ...
        - ...
    validations:
      required: true

  - type: dropdown
    id: topic
    attributes:
      label: Topic
      description: Which area is your question about?
      options:
        - Local Development
        - Docker & Containers
        - GitHub Actions & CI/CD
        - Azure Deployment
        - Security & Vulnerabilities
        - Training & Exercises
        - Other

  - type: textarea
    id: additional
    attributes:
      label: Additional Details
      description: Anything else?
      placeholder: Error messages, logs, screenshots, etc.
