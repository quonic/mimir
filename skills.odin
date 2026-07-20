package main

import "core:strings"

Skill_Scope :: enum int {
	Global = 0,
	Project,
}

Skill :: struct {
	name:  string,
	path:  string,
	body:  string,
	scope: Skill_Scope,
}

Skill_Registry :: struct {
	skills: [dynamic]Skill,
}

skill_registry_init :: proc(allocator := context.allocator) -> Skill_Registry {
	registry: Skill_Registry
	registry.skills = make([dynamic]Skill, 0, 0, allocator)
	return registry
}

global_skill_dir :: proc(home: string, allocator := context.allocator) -> string {
	if home == "" {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, home)
	strings.write_string(&builder, "/.config/mimir/skills")
	return strings.to_string(builder)
}

project_skill_dir :: proc(projectRoot: string, allocator := context.allocator) -> string {
	if projectRoot == "" {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, projectRoot)
	strings.write_string(&builder, "/.mimir/skills")
	return strings.to_string(builder)
}

skill_name_from_path :: proc(path: string) -> string {
	start := 0
	for index := 0; index < len(path); index += 1 {
		if path[index] == '/' {
			start = index + 1
		}
	}

	finish := len(path)
	if finish - start > 3 && path[finish - 3:] == ".md" {
		finish -= 3
	}
	return path[start:finish]
}
