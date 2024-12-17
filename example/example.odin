package main

import "core:os"
import "core:fmt"

import vorbis "../"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("Please provide a vorbis file")
		return
	}

	vorbis.load(os.args[1])
}
