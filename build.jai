#import "Compiler";

#run
{
    {
        w := compiler_create_workspace("Debug");

        options := get_build_options();
        options.output_executable_name = "spectral_debug";
        options.output_path            = "run";
        options.optimization_level     = .DEBUG;

        set_build_options(options, w);

        add_build_string("DEBUG :: true;", w);
        add_build_file("src/main.jai", w);
    }

    {
        w := compiler_create_workspace("Release");

        options := get_build_options();
        options.output_executable_name = "spectral";
        options.output_path            = "run";
        options.optimization_level     = .RELEASE;
        options.array_bounds_check     = .OFF;
        options.cast_bounds_check      = .OFF;

        options.llvm_options.code_gen_optimization_level = 2;
        options.llvm_options.disable_inlining            = false;
        options.llvm_options.enable_loop_unrolling       = true;
        options.llvm_options.enable_loop_vectorization   = true;
        options.llvm_options.enable_slp_vectorization    = true;
        options.llvm_options.enable_tail_calls           = true;

        set_build_options(options, w);

        add_build_string("DEBUG :: false;", w);
        add_build_file("src/main.jai", w);
    }

    set_build_options_dc(.{do_output=false});
}
