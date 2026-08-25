package settings

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
