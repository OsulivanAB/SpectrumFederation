"""
Validates that PR descriptions follow the required template format.
"""

import os
import re
import sys


def parse_pr_body(body):
    """Parse PR body and extract sections."""
    if not body:
        return None, None
    
    # Find Type of Change section
    type_of_change_pattern = r'## Type of Change\s*(.*?)(?=##|\Z)'
    type_match = re.search(type_of_change_pattern, body, re.DOTALL | re.IGNORECASE)
    type_section = type_match.group(1).strip() if type_match else None
    
    # Find Checklist section
    checklist_pattern = r'## Checklist\s*(.*?)(?=##|\Z)'
    checklist_match = re.search(checklist_pattern, body, re.DOTALL | re.IGNORECASE)
    checklist_section = checklist_match.group(1).strip() if checklist_match else None
    
    return type_section, checklist_section


def count_checkboxes(section, optional_phrases=None):
    """Count total and checked checkboxes in a section."""
    if not section:
        return 0, 0

    optional_phrases = optional_phrases or []
    checkbox_pattern = re.compile(r'-\s*\[([\sxX])\]\s*(.+)')

    total = 0
    checked = 0

    for match in checkbox_pattern.finditer(section):
        state = match.group(1)
        label = match.group(2).strip().lower()

        if any(phrase in label for phrase in optional_phrases):
            continue

        total += 1
        if state.lower() == 'x':
            checked += 1

    return total, checked


def main():
    pr_body = os.environ.get('PR_BODY', '')
    
    if not pr_body:
        print("❌ ERROR: PR body is empty")
        sys.exit(1)
    
    print("🔍 Validating PR description...")
    print()
    
    # Parse sections
    type_section, checklist_section = parse_pr_body(pr_body)
    
    errors = []
    
    # Validate Type of Change section
    if not type_section:
        errors.append("Missing '## Type of Change' section")
    else:
        total_type, checked_type = count_checkboxes(type_section)
        print(f"✓ Found 'Type of Change' section with {total_type} options")
        
        if checked_type == 0:
            errors.append("No checkbox is selected in 'Type of Change' section")
        else:
            print(f"✓ {checked_type} type(s) selected")
    
    print()
    
    # Validate Checklist section
    if not checklist_section:
        errors.append("Missing '## Checklist' section")
    else:
        optional_items = ["linked this pr to any related issues"]
        total_checklist, checked_checklist = count_checkboxes(checklist_section, optional_items)
        print(f"✓ Found 'Checklist' section with {total_checklist} items")
        
        if total_checklist == 0:
            errors.append("No checklist items found in 'Checklist' section")
        elif checked_checklist < total_checklist:
            errors.append(
                f"Not all checklist items are checked: {checked_checklist}/{total_checklist} completed"
            )
        else:
            print(f"✓ All {total_checklist} checklist items are checked")
    
    print()
    
    # Report results
    if errors:
        print("❌ PR description validation FAILED:")
        print()
        for error in errors:
            print(f"  • {error}")
        print()
        sys.exit(1)
    else:
        print("✅ PR description validation PASSED!")
        sys.exit(0)


if __name__ == '__main__':
    main()
