package examples

import ai "../"
import "core:fmt"

stream_chat_delta :: proc(delta: ai.Chat_Stream_Delta) -> bool {
	if delta.content != "" {
		fmt.print(delta.content)
	}

	if delta.done {
		fmt.println()
		if delta.finishReason != "" {
			fmt.println("stream finished: ", delta.finishReason)
		} else {
			fmt.println("stream finished")
		}
	}

	return true
}

STREAM :: true
MODEL :: "qwen3.6:35b"
QUESTION :: "How do I start a camp fire?"

main :: proc() {

	ai.add_interface("ollama", .Ollama, "http://localhost:11434")

	client, err := ai.new_client("ollama", "")
	if err != .None {
		// handle interface lookup failure
		fmt.eprintfln("failed to create client: %v", err)
		return
	}


	when ODIN_DEBUG {
		models, err := ai.list_models(client)
		defer ai.free_model_list(models)
		if err != .None {
			// handle model listing failure
			fmt.eprintfln("failed to list models: %v", err)
			return
		}

		fmt.println("available models:")
		for model in models {
			fmt.println(model)
		}
	}

	if STREAM {
		err_resp := ai.send_chat_completion_stream(
			client,
			ai.Chat_Request {
				model = MODEL,
				messages = []ai.Message{{role = .User, content = QUESTION}},
				temperature = 0.2,
				maxTokens = 100000,
			},
			stream_chat_delta,
		)
		if err_resp != .None {
			// handle chat completion failure
			fmt.eprintfln("chat completion failed: %v", err_resp)
			return
		}
	} else {
		response, err_resp := ai.send_chat_completion(
			client,
			ai.Chat_Request {
				model = MODEL,
				messages = []ai.Message{{role = .User, content = QUESTION}},
				temperature = 0.2,
				maxTokens = 100000,
			},
		)
		if err_resp != .None {
			// handle chat completion failure
			fmt.eprintfln("chat completion failed: %v", err_resp)
			return
		}

		fmt.println("chat completion finished:")
		fmt.printfln("%s", response.content)
	}
}
