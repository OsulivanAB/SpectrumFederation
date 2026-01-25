# GitHub Copilot Agent Instructions

This directory contains specialized instructions for GitHub Copilot agents working on the SpectrumFederation repository.

## Purpose

These instruction files help ensure that GitHub Copilot agents:
1. **Always bump the version** in the `.toc` file when making code changes
2. Follow project-specific conventions and patterns
3. Understand the WoW addon development context
4. Apply appropriate testing and validation procedures

## How It Works

GitHub Copilot Workspace and GitHub Copilot agents can read instructions from the `.github/agents/` directory to get context-specific guidance. These instructions supplement the main `.github/copilot-instructions.md` file.

## Instruction Files

### `general.md`
- **Audience**: All agents
- **Purpose**: Universal guidelines that apply to any task
- **Key Focus**: Version bumping requirement, repository structure, basic workflow

### `code-changes.md`
- **Audience**: Agents making code changes (new features, bug fixes, refactoring)
- **Purpose**: Detailed workflow for code modifications
- **Key Focus**: Mandatory version bumping, code patterns, testing procedures

### `documentation.md`
- **Audience**: Agents updating documentation
- **Purpose**: Guidelines for documentation changes
- **Key Focus**: When version bumping is/isn't needed for docs, MkDocs formatting

## Primary Goal: Version Bumping

**The #1 issue these instructions solve**: Agents forgetting to bump the version in `SpectrumFederation/SpectrumFederation.toc`

All instruction files emphasize:
- Version bumping is **MANDATORY** for code/behavioral changes
- It should be the **FIRST STEP** in any code change workflow
- CI will **FAIL** if version is not bumped
- Instructions on **HOW** to bump versions correctly (beta vs stable)

## Usage by Agents

When GitHub Copilot agents work on this repository, they should:

1. Read `.github/copilot-instructions.md` for general project context
2. Read the appropriate agent instruction file:
   - Making code changes? → Read `code-changes.md`
   - Updating docs? → Read `documentation.md`
   - Other tasks? → Read `general.md`
3. **Follow the version bumping instructions FIRST**
4. Complete the task following project conventions
5. Verify version was bumped before committing

## For Human Developers

These files are also useful references for human developers, especially when:
- Contributing to the project for the first time
- Understanding the CI/CD requirements
- Learning the project's conventions
- Setting up their own AI coding assistants

## Maintaining These Instructions

When updating these files:
- Keep version bumping instructions **prominent and repeated**
- Include **concrete examples** (e.g., `0.4.0-beta.7` → `0.4.0-beta.8`)
- Cross-reference the main copilot-instructions.md file
- Update all files when project structure or requirements change
- Test instructions by creating sample PRs with AI assistance

## Related Files

- `.github/copilot-instructions.md` - Main Copilot instructions (comprehensive project guide)
- `.github/workflows/pr-*-validation.yml` - CI workflows that enforce version bumping
- `.github/scripts/check_version_bump.py` - Script that validates version changes
- `SpectrumFederation/SpectrumFederation.toc` - The file where version MUST be bumped

## Version Bump Validation

The CI workflow runs this check on every PR:
```bash
python3 .github/scripts/check_version_bump.py beta  # or 'main'
```

This script:
1. Reads version from current branch's `.toc` file
2. Reads version from base branch's `.toc` file
3. Compares them
4. **Fails CI if they're identical**

This is why version bumping is non-negotiable.

## Common Questions

**Q: Why is version bumping so important?**  
A: The version triggers automated release workflows, tracks changes, and is required for WoW addon distribution platforms.

**Q: What if I'm just fixing a typo in a comment?**  
A: If it's truly just a comment (no behavioral change), version bump may not be needed. But when in doubt, bump it.

**Q: Can I bump version after making changes?**  
A: Yes, but it's better to do it first so you don't forget. CI will catch it if you forget, but that wastes time.

**Q: How do I know what version number to use?**  
A: Check the base branch version and increment:
- Beta: increment the number after `-beta.` (e.g., 7 → 8)
- Stable: increment patch (0.4.0 → 0.4.1) for fixes, minor (0.4.0 → 0.5.0) for features

**Q: What if CI fails even though I bumped the version?**  
A: Check that you bumped the right `.toc` file (`SpectrumFederation/SpectrumFederation.toc`) and saved it.

## See Also

- [GitHub Copilot Workspace Documentation](https://githubnext.com/projects/copilot-workspace)
- [WoW AddOn Development](https://wowpedia.fandom.com/wiki/AddOn)
- [Semantic Versioning](https://semver.org/)
