package settings

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_skill_paths_and_names :: proc(t: ^testing.T) {
	globalDir := global_skill_dir("/home/test", context.temp_allocator)
	defer delete(globalDir, context.temp_allocator)
	projectDir := project_skill_dir("/repo", context.temp_allocator)
	defer delete(projectDir, context.temp_allocator)

	assert(globalDir == "/home/test/.config/mimir/skills", "expected global skills directory")
	assert(projectDir == "/repo/.mimir/skills", "expected project skills directory")
	assert(skill_name_from_path("/repo/.mimir/skills/odin.md") == "odin", "expected name")
	_ = t
}

@(test)
test_skill_name_validation_accepts_lowercase_unicode :: proc(t: ^testing.T) {
	assert(skill_name_valid("café-tools"), "expected lowercase Unicode skill name")
	assert(!skill_name_valid("Cafe-tools"), "expected uppercase skill name to reject")
	assert(!skill_name_valid("tool--name"), "expected consecutive hyphens to reject")
	_ = t
}

@(test)
test_skill_parser_retains_nested_metadata :: proc(t: ^testing.T) {
	root, rootErr := os.make_directory_temp("", "skill_metadata_", context.temp_allocator)
	assert(rootErr == nil, "expected temporary directory")
	defer os.remove_all(root)
	skillRoot := strings.concatenate({root, "/metadata"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	path := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			path,
			"---\n# skill metadata\nname: metadata\ndescription: Metadata skill\nmetadata:\n  author: example\n  version: '1.0'\n---\nbody",
		) ==
		nil,
		"expected skill file",
	)
	skill, message, ok := skill_parse_file(path, skillRoot, .Project, context.temp_allocator)
	defer skill_destroy(&skill, context.temp_allocator)
	assert(ok && message == "", "expected metadata skill to parse")
	assert(len(skill.metadata) == 2, "expected nested metadata entries")
	assert(skill.metadata[0].key == "author", "expected metadata key")
	assert(skill.metadata[1].value == "1.0", "expected quoted metadata value")
	_ = t
}

@(test)
test_skill_parser_rejects_duplicate_fields :: proc(t: ^testing.T) {
	root, rootErr := os.make_directory_temp("", "skill_duplicate_", context.temp_allocator)
	assert(rootErr == nil, "expected temporary directory")
	defer os.remove_all(root)
	skillRoot := strings.concatenate({root, "/duplicate"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	path := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			path,
			"---\nname: duplicate\nname: duplicate\ndescription: Duplicate skill\n---\nbody",
		) == nil,
		"expected skill file",
	)
	_, message, ok := skill_parse_file(path, skillRoot, .Project, context.temp_allocator)
	assert(!ok && strings.contains(message, "duplicate name"), "expected duplicate name rejection")
	delete(message, context.temp_allocator)
	_ = t
}

@(test)
test_skill_registry_discovers_project_before_global_and_loads_body :: proc(t: ^testing.T) {
	home, homeErr := os.make_directory_temp("", "skills_home_", context.temp_allocator)
	project, projectErr := os.make_directory_temp("", "skills_project_", context.temp_allocator)
	assert(homeErr == nil && projectErr == nil, "expected temporary directories")
	defer os.remove_all(home)
	defer os.remove_all(project)

	projectSkill := strings.concatenate({project, "/.mimir/skills/odin"}, context.temp_allocator)
	globalSkill := strings.concatenate(
		{home, "/.config/mimir/skills/odin"},
		context.temp_allocator,
	)
	assert(os.make_directory_all(projectSkill) == nil, "expected project skill directory")
	assert(os.make_directory_all(globalSkill) == nil, "expected global skill directory")
	projectFile := strings.concatenate({projectSkill, "/SKILL.md"}, context.temp_allocator)
	globalFile := strings.concatenate({globalSkill, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			projectFile,
			"---\nname: odin\ndescription: Project skill\n---\nproject body",
		) ==
		nil,
		"expected project skill file",
	)
	assert(
		os.write_entire_file_from_string(
			globalFile,
			"---\nname: odin\ndescription: Global skill\n---\nglobal body",
		) ==
		nil,
		"expected global skill file",
	)

	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, home, project)
	assert(len(registry.skills) == 1, "expected duplicate skill to load once")
	assert(registry.skills[0].description == "Project skill", "expected project precedence")
	body, bodyOK := skill_registry_read(&registry, "odin")
	defer delete(body, context.temp_allocator)
	assert(bodyOK && strings.contains(body, "project body"), "expected project skill body")
	_ = t
}

@(test)
test_skill_registry_reports_invalid_skill_and_rejects_disabled_skill :: proc(t: ^testing.T) {
	project, projectErr := os.make_directory_temp("", "skills_invalid_", context.temp_allocator)
	assert(projectErr == nil, "expected temporary directory")
	defer os.remove_all(project)
	skillRoot := strings.concatenate({project, "/.mimir/skills/bad"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	skillPath := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(os.write_entire_file_from_string(skillPath, "name: bad") == nil, "expected skill file")

	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, "", project)
	assert(len(registry.skills) == 0, "expected invalid skill to be skipped")
	assert(len(registry.diagnostics) == 1, "expected invalid skill diagnostic")

	validRoot := strings.concatenate({project, "/.mimir/skills/good"}, context.temp_allocator)
	assert(os.make_directory_all(validRoot) == nil, "expected valid skill directory")
	validPath := strings.concatenate({validRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			validPath,
			"---\nname: good\ndescription: Good skill\n---\nbody",
		) ==
		nil,
		"expected valid skill file",
	)
	skill_registry_load(&registry, "", project)
	registry.skills[0].enabled = false
	_, readOK := skill_registry_read(&registry, "good")
	assert(!readOK, "expected disabled skill to be rejected")
	_ = t
}

@(test)
test_skill_registry_rejects_resource_path_escape :: proc(t: ^testing.T) {
	project, projectErr := os.make_directory_temp("", "skills_resource_", context.temp_allocator)
	assert(projectErr == nil, "expected temporary directory")
	defer os.remove_all(project)
	skillRoot := strings.concatenate({project, "/.mimir/skills/good"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	skillPath := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			skillPath,
			"---\nname: good\ndescription: Good skill\n---\nbody",
		) ==
		nil,
		"expected skill file",
	)

	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, "", project)
	_, readOK := skill_registry_read_resource(&registry, "good", "../outside.txt")
	assert(!readOK, "expected resource traversal to be rejected")
	_ = t
}

@(test)
test_skill_registry_catalog_excludes_disabled_skills :: proc(t: ^testing.T) {
	project, projectErr := os.make_directory_temp("", "skills_catalog_", context.temp_allocator)
	assert(projectErr == nil, "expected temporary directory")
	defer os.remove_all(project)
	skillRoot := strings.concatenate({project, "/.mimir/skills/good"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	skillPath := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			skillPath,
			"---\nname: good\ndescription: Good skill\n---\nbody",
		) ==
		nil,
		"expected skill file",
	)

	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, "", project)
	catalog := skill_registry_prompt_catalog(&registry, context.temp_allocator)
	assert(strings.contains(catalog, "good: Good skill"), "expected enabled skill in catalog")
	delete(catalog, context.temp_allocator)
	registry.skills[0].enabled = false
	catalog = skill_registry_prompt_catalog(&registry, context.temp_allocator)
	assert(catalog == "", "expected disabled skill omitted from catalog")
	delete(catalog, context.temp_allocator)
	_ = t
}

@(test)
test_skill_registry_rejects_symlink_resource :: proc(t: ^testing.T) {
	project, projectErr := os.make_directory_temp("", "skill_symlink_", context.temp_allocator)
	assert(projectErr == nil, "expected temporary directory")
	defer os.remove_all(project)
	skillRoot := strings.concatenate({project, "/.mimir/skills/good"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	skillPath := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	outsidePath := strings.concatenate({project, "/outside.txt"}, context.temp_allocator)
	linkPath := strings.concatenate({skillRoot, "/reference.txt"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			skillPath,
			"---\nname: good\ndescription: Good skill\n---\nbody",
		) ==
		nil,
		"expected skill file",
	)
	assert(
		os.write_entire_file_from_string(outsidePath, "outside") == nil,
		"expected outside file",
	)
	assert(os.symlink(outsidePath, linkPath) == nil, "expected resource symlink")

	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, "", project)
	_, readOK := skill_registry_read_resource(&registry, "good", "reference.txt")
	assert(!readOK, "expected symlink resource to be rejected")
	_ = t
}

@(test)
test_skill_registry_body_uses_exact_frontmatter_delimiter :: proc(t: ^testing.T) {
	root, rootErr := os.make_directory_temp("", "skill_body_", context.temp_allocator)
	assert(rootErr == nil, "expected temporary directory")
	defer os.remove_all(root)
	skillRoot := strings.concatenate({root, "/.mimir/skills/delimiters"}, context.temp_allocator)
	assert(os.make_directory_all(skillRoot) == nil, "expected skill directory")
	path := strings.concatenate({skillRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			path,
			"---\nname: delimiters\ndescription: Value with --- text\n---\nbody with --- text",
		) ==
		nil,
		"expected skill file",
	)
	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, "", root)
	body, ok := skill_registry_read(&registry, "delimiters")
	defer delete(body, context.temp_allocator)
	assert(ok && strings.contains(body, "body with --- text"), "expected complete skill body")
	_ = t
}

@(test)
test_skill_registry_skips_symlinked_skill_root :: proc(t: ^testing.T) {
	project, projectErr := os.make_directory_temp("", "skill_root_link_", context.temp_allocator)
	assert(projectErr == nil, "expected temporary directory")
	defer os.remove_all(project)
	realRoot := strings.concatenate({project, "/real"}, context.temp_allocator)
	skillParent := strings.concatenate({project, "/.mimir/skills"}, context.temp_allocator)
	linkRoot := strings.concatenate({skillParent, "/linked"}, context.temp_allocator)
	assert(os.make_directory_all(realRoot) == nil, "expected real skill directory")
	assert(os.make_directory_all(skillParent) == nil, "expected skill parent directory")
	skillPath := strings.concatenate({realRoot, "/SKILL.md"}, context.temp_allocator)
	assert(
		os.write_entire_file_from_string(
			skillPath,
			"---\nname: linked\ndescription: Linked skill\n---\nbody",
		) ==
		nil,
		"expected skill file",
	)
	assert(os.symlink(realRoot, linkRoot) == nil, "expected skill-root symlink")

	registry := skill_registry_init(context.temp_allocator)
	defer skill_registry_destroy(&registry)
	skill_registry_load(&registry, "", project)
	assert(len(registry.skills) == 0, "expected symlinked skill root to be skipped")
	_ = t
}
