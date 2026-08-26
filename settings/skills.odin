package settings

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

MAX_SKILL_BODY_BYTES :: 1024 * 1024

Skill_Metadata :: struct {
	key:   string,
	value: string,
}

Skill_Scope :: enum int {
	Global = 0,
	Project,
}

Skill :: struct {
	name:          string,
	description:   string,
	license:       string,
	compatibility: string,
	allowedTools:  string,
	metadata:      [dynamic]Skill_Metadata,
	path:          string,
	root:          string,
	body:          string,
	bodyLoaded:    bool,
	enabled:       bool,
	scope:         Skill_Scope,
}

Skill_Diagnostic :: struct {
	path:    string,
	message: string,
}

Skill_Registry :: struct {
	skills:      [dynamic]Skill,
	diagnostics: [dynamic]Skill_Diagnostic,
	allocator:   mem.Allocator,
}

skill_registry_init :: proc(allocator := context.allocator) -> Skill_Registry {
	registry: Skill_Registry
	registry.skills = make([dynamic]Skill, 0, 0, allocator)
	registry.diagnostics = make([dynamic]Skill_Diagnostic, 0, 0, allocator)
	registry.allocator = allocator
	return registry
}

skill_destroy :: proc(skill: ^Skill, allocator: mem.Allocator) {
	delete(skill.name, allocator)
	delete(skill.description, allocator)
	delete(skill.license, allocator)
	delete(skill.compatibility, allocator)
	delete(skill.allowedTools, allocator)
	for &entry in skill.metadata {
		delete(entry.key, allocator)
		delete(entry.value, allocator)
	}
	delete(skill.metadata)
	delete(skill.path, allocator)
	delete(skill.root, allocator)
	delete(skill.body, allocator)
	skill^ = {}
}

skill_registry_destroy :: proc(registry: ^Skill_Registry) {
	for &skill in registry.skills {
		skill_destroy(&skill, registry.allocator)
	}
	for &diagnostic in registry.diagnostics {
		delete(diagnostic.path, registry.allocator)
		delete(diagnostic.message, registry.allocator)
	}
	delete(registry.skills)
	delete(registry.diagnostics)
	registry^ = {}
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

skill_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 64 || name[0] == '-' || name[len(name) - 1] == '-' {
		return false
	}
	for index := 0; index < len(name); index += 1 {
		character := name[index]
		if character == '-' {
			if index > 0 && name[index - 1] == '-' {
				return false
			}
			continue
		}
		if !((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')) {
			return false
		}
	}
	return true
}

skill_frontmatter_value :: proc(value: string) -> string {
	result := strings.trim(value, " \t")
	if len(result) >= 2 && result[0] == '"' && result[len(result) - 1] == '"' {
		result = result[1:len(result) - 1]
	}
	return result
}

skill_parse_file :: proc(
	path: string,
	root: string,
	scope: Skill_Scope,
	allocator := context.allocator,
) -> (
	Skill,
	string,
	bool,
) {
	data, readErr := os.read_entire_file(path, context.temp_allocator)
	if readErr != nil {
		return {},
			fmt.aprintf("could not read SKILL.md: %s", readErr, allocator = allocator),
			false
	}
	text := string(data)
	lines := strings.split(text, "\n")
	defer delete(lines)
	if len(lines) < 3 || strings.trim(lines[0], " \t\r") != "---" {
		return {}, strings.clone("missing YAML frontmatter", allocator), false
	}

	skill := Skill {
		path     = strings.clone(path, allocator),
		root     = strings.clone(root, allocator),
		scope    = scope,
		enabled  = true,
		metadata = make([dynamic]Skill_Metadata, 0, 4, allocator),
	}
	frontmatterEnd := -1
	for index := 1; index < len(lines); index += 1 {
		line := strings.trim(lines[index], " \t\r")
		if line == "---" {
			frontmatterEnd = index
			break
		}
		separator := strings.index_byte(line, ':')
		if separator < 0 {
			skill_destroy(&skill, allocator)
			return {},
				fmt.aprintf("invalid frontmatter line: %s", line, allocator = allocator),
				false
		}
		key := line[:separator]
		value := skill_frontmatter_value(line[separator + 1:])
		switch key {
		case "name":
			skill.name = strings.clone(value, allocator)
		case "description":
			skill.description = strings.clone(value, allocator)
		case "license":
			skill.license = strings.clone(value, allocator)
		case "compatibility":
			skill.compatibility = strings.clone(value, allocator)
		case "allowed-tools":
			skill.allowedTools = strings.clone(value, allocator)
		case "metadata":
			continue
		case:
			if strings.starts_with(lines[index], " ") || strings.starts_with(lines[index], "\t") {
				append(
					&skill.metadata,
					Skill_Metadata {
						key = strings.clone(key, allocator),
						value = strings.clone(value, allocator),
					},
				)
			}
		}
	}
	if frontmatterEnd < 0 {
		skill_destroy(&skill, allocator)
		return {}, strings.clone("unterminated YAML frontmatter", allocator), false
	}
	if !skill_name_valid(skill.name) {
		skill_destroy(&skill, allocator)
		return {}, strings.clone("invalid skill name", allocator), false
	}
	if skill.name != skill_name_from_path(root) &&
	   skill.name != skill_name_from_path(path[:len(path) - len("/SKILL.md")]) {
		skill_destroy(&skill, allocator)
		return {}, strings.clone("skill name does not match directory name", allocator), false
	}
	if len(skill.description) == 0 || len(skill.description) > 1024 {
		skill_destroy(&skill, allocator)
		return {}, strings.clone("invalid skill description", allocator), false
	}
	if len(skill.compatibility) > 500 {
		skill_destroy(&skill, allocator)
		return {}, strings.clone("skill compatibility is too long", allocator), false
	}
	return skill, "", true
}

skill_registry_add_diagnostic :: proc(registry: ^Skill_Registry, path, message: string) {
	append(
		&registry.diagnostics,
		Skill_Diagnostic {
			path = strings.clone(path, registry.allocator),
			message = strings.clone(message, registry.allocator),
		},
	)
}

skill_registry_has_name :: proc(registry: ^Skill_Registry, name: string) -> bool {
	for skill in registry.skills {
		if skill.name == name {
			return true
		}
	}
	return false
}

skill_registry_load_root :: proc(registry: ^Skill_Registry, path: string, scope: Skill_Scope) {
	entries, err := os.read_directory_by_path(path, 0, registry.allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(entries, registry.allocator)
	for entry in entries {
		if entry.name == "." || entry.name == ".." {
			continue
		}
		skillRoot := fmt.aprintf("%s/%s", path, entry.name, allocator = registry.allocator)
		skillPath := fmt.aprintf("%s/SKILL.md", skillRoot, allocator = registry.allocator)
		if !os.is_directory(skillRoot) ||
		   !os.exists(skillPath) ||
		   skill_registry_has_name(registry, entry.name) {
			delete(skillRoot, registry.allocator)
			delete(skillPath, registry.allocator)
			continue
		}
		skill, message, ok := skill_parse_file(skillPath, skillRoot, scope, registry.allocator)
		if !ok {
			skill_registry_add_diagnostic(registry, skillPath, message)
		} else {
			append(&registry.skills, skill)
		}
		delete(skillRoot, registry.allocator)
		delete(skillPath, registry.allocator)
	}
}

skill_registry_load :: proc(registry: ^Skill_Registry, home: string, projectRoot: string) {
	for &skill in registry.skills {
		skill_destroy(&skill, registry.allocator)
	}
	for &diagnostic in registry.diagnostics {
		delete(diagnostic.path, registry.allocator)
		delete(diagnostic.message, registry.allocator)
	}
	clear(&registry.skills)
	clear(&registry.diagnostics)
	globalMimir := global_skill_dir(home, registry.allocator)
	projectMimir := project_skill_dir(projectRoot, registry.allocator)
	globalAgents := fmt.aprintf("%s/.agents/skills", home, allocator = registry.allocator)
	projectAgents := fmt.aprintf("%s/.agents/skills", projectRoot, allocator = registry.allocator)
	defer {
		delete(globalMimir, registry.allocator)
		delete(projectMimir, registry.allocator)
		delete(globalAgents, registry.allocator)
		delete(projectAgents, registry.allocator)
	}
	// Project skills take precedence over global skills; the first match wins.
	skill_registry_load_root(registry, projectMimir, .Project)
	skill_registry_load_root(registry, globalMimir, .Global)
	skill_registry_load_root(registry, projectAgents, .Project)
	skill_registry_load_root(registry, globalAgents, .Global)
}

skill_registry_find :: proc(registry: ^Skill_Registry, name: string) -> (^Skill, bool) {
	for index := 0; index < len(registry.skills); index += 1 {
		if registry.skills[index].name == name {
			return &registry.skills[index], true
		}
	}
	return nil, false
}

skill_registry_apply_disabled :: proc(registry: ^Skill_Registry, disabledNames: []string) {
	for &skill in registry.skills {
		skill.enabled = true
		for name in disabledNames {
			if skill.name == name {
				skill.enabled = false
				break
			}
		}
	}
}

skill_registry_prompt_catalog :: proc(
	registry: ^Skill_Registry,
	allocator := context.allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for skill in registry.skills {
		if !skill.enabled {
			continue
		}
		if len(builder.buf) > 0 {
			strings.write_byte(&builder, '\n')
		}
		strings.write_string(&builder, "- ")
		strings.write_string(&builder, skill.name)
		strings.write_string(&builder, ": ")
		strings.write_string(&builder, skill.description)
	}
	if len(builder.buf) == 0 {
		return ""
	}
	return strings.to_string(builder)
}

skill_registry_count :: proc(registry: ^Skill_Registry) -> int {
	return len(registry.skills)
}

skill_registry_diagnostic_count :: proc(registry: ^Skill_Registry) -> int {
	return len(registry.diagnostics)
}

skill_registry_skill_at :: proc(registry: ^Skill_Registry, index: int) -> (^Skill, bool) {
	if index < 0 || index >= len(registry.skills) {
		return nil, false
	}
	return &registry.skills[index], true
}

skill_registry_diagnostic_at :: proc(
	registry: ^Skill_Registry,
	index: int,
) -> (
	^Skill_Diagnostic,
	bool,
) {
	if index < 0 || index >= len(registry.diagnostics) {
		return nil, false
	}
	return &registry.diagnostics[index], true
}

skill_name :: proc(skill: ^Skill) -> string {
	return skill.name
}

skill_is_enabled :: proc(skill: ^Skill) -> bool {
	return skill.enabled
}

skill_set_enabled :: proc(skill: ^Skill, enabled: bool) {
	skill.enabled = enabled
}

skill_registry_read :: proc(registry: ^Skill_Registry, name: string) -> (string, bool) {
	skill, ok := skill_registry_find(registry, name)
	if !ok || !skill.enabled {
		return strings.clone("Skill is unavailable.", registry.allocator), false
	}
	if !skill.bodyLoaded {
		data, err := os.read_entire_file(skill.path, registry.allocator)
		if err != nil || len(data) > MAX_SKILL_BODY_BYTES {
			return strings.clone("Skill body could not be loaded.", registry.allocator), false
		}
		text := string(data)
		separator := strings.index(text[3:], "---")
		if separator < 0 {
			delete(data, registry.allocator)
			return strings.clone("Skill body has invalid frontmatter.", registry.allocator), false
		}
		separator += 3
		bodyStart := strings.index_byte(text[separator:], '\n')
		if bodyStart < 0 {
			delete(data, registry.allocator)
			return strings.clone("Skill body is empty.", registry.allocator), false
		}
		bodyStart += separator
		skill.body = strings.clone(text[bodyStart + 1:], registry.allocator)
		skill.bodyLoaded = true
		delete(data, registry.allocator)
	}
	return fmt.aprintf(
			"name: %s\ndescription: %s\n\n%s",
			skill.name,
			skill.description,
			skill.body,
			allocator = registry.allocator,
		),
		true
}

skill_registry_read_resource :: proc(
	registry: ^Skill_Registry,
	name: string,
	relativePath: string,
) -> (
	string,
	bool,
) {
	skill, ok := skill_registry_find(registry, name)
	if !ok || !skill.enabled || relativePath == "" || relativePath[0] == '/' {
		return strings.clone("Skill resource is unavailable.", registry.allocator), false
	}
	if relativePath == ".." ||
	   strings.starts_with(relativePath, "../") ||
	   strings.contains(relativePath, "/../") {
		return strings.clone(
				"Skill resource path is outside the skill directory.",
				registry.allocator,
			),
			false
	}
	path := fmt.aprintf("%s/%s", skill.root, relativePath, allocator = registry.allocator)
	defer delete(path, registry.allocator)
	data, err := os.read_entire_file(path, registry.allocator)
	if err != nil || len(data) > MAX_SKILL_BODY_BYTES {
		return strings.clone("Skill resource could not be loaded.", registry.allocator), false
	}
	return strings.clone(string(data), registry.allocator), true
}
