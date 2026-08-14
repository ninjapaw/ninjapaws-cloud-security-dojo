name: 💡 Feature Request
description: Suggest an enhancement to the Ninja Paws Cloud Security Dojo
title: "[FEATURE] "
labels: ["enhancement"]

body:
  - type: markdown
    attributes:
      value: |
        Thank you for suggesting an enhancement!
        
        Please describe how this feature would improve the training experience.

  - type: textarea
    id: problem
    attributes:
      label: Problem or Use Case
      description: What problem does this solve or what gap does it fill?
      placeholder: |
        Currently, [current situation].
        This makes it difficult to [what's hard].
        A feature to [suggestion] would help because [benefit].
    validations:
      required: true

  - type: textarea
    id: solution
    attributes:
      label: Proposed Solution
      description: How should this feature work?
      placeholder: |
        The feature should:
        1. ...
        2. ...
        3. ...
    validations:
      required: true

  - type: textarea
    id: alternative
    attributes:
      label: Alternative Approaches
      description: Any other ways to solve this?
      placeholder: |
        - Approach 1: ...
        - Approach 2: ...

  - type: textarea
    id: learning
    attributes:
      label: Learning Value
      description: How does this improve the training experience?
      placeholder: |
        This feature teaches learners about...
        It demonstrates...
    validations:
      required: true

  - type: textarea
    id: context
    attributes:
      label: Additional Context
      description: Anything else?
      placeholder: Screenshots, links, references, etc.

  - type: checkboxes
    id: checklist
    attributes:
      label: Checklist
      options:
        - label: This is educational and aligns with training goals
          required: true
        - label: It doesn't introduce credentials or sensitive data
          required: true
        - label: I've searched for similar suggestions
          required: true
