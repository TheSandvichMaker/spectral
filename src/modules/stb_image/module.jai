// stb_image bindings.

stbi_load             :: (filename: *u8,         x: *s32, y: *s32, comp: *s32, req_comp: s32) -> *u8  #foreign stb_image;
stbi_load_from_memory :: (buffer: *u8, len: s32, x: *s32, y: *s32, comp: *s32, req_comp: s32) -> *u8  #foreign stb_image;

stbi_set_flip_vertically_on_load :: (flag_true_if_should_flip: s32) #foreign stb_image;

stbi_image_free       :: (retval_from_stbi_load: *u8)  #foreign stb_image;

#scope_file

#if OS == .WINDOWS {
	stb_image :: #foreign_library "win/stb_image";
} else #if OS == .LINUX {
	stb_image :: #foreign_library "linux/stb_image";
} else #if OS == .MACOS {
	stb_image :: #foreign_library "mac/stb_image";
}

#if 0 {
    #import "Compiler";
    #import "BuildCpp";
    #import "Basic";

    #run {
        print("Building dynamic library:\n");
        build_cpp_dynamic_lib("stb_image", "source/stb_image.cpp");

        print("Building static library:\n");
        build_cpp_static_lib("stb_image", "source/stb_image.cpp");

        set_build_options_dc(.{do_output = false});
    };
}
