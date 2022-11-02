#import "Compiler";

#run
{
    shared_options := get_build_options();
    shared_options.import_path            = .[ "src/modules", "C:/jai/modules", ];
    shared_options.output_path            = "run";

    {
        w := compiler_create_workspace("Debug");

        options := shared_options;
        options.output_executable_name = "spectral_debug";
        options.optimization_level     = .DEBUG;

        set_build_options(options, w);

        add_build_string("DEBUG :: true;", w);
        add_build_file("src/main.jai", w);
    }

    {
        w := compiler_create_workspace("Release");

        options := shared_options;
        options.output_executable_name  = "spectral";
        options.array_bounds_check      = .OFF;
        options.cast_bounds_check       = .OFF;
        options.enable_bytecode_inliner = true;
        options.optimization_level      = .RELEASE;

        options.llvm_options.code_gen_optimization_level = 2;
        options.llvm_options.disable_inlining            = false;
        options.llvm_options.enable_loop_unrolling       = true;
        options.llvm_options.enable_loop_vectorization   = true;
        options.llvm_options.enable_slp_vectorization    = true;
        options.llvm_options.enable_tail_calls           = true;

        set_build_options(options, w);

        add_build_string("DEBUG :: true;", w);
        add_build_file("src/main.jai", w);
    }

    set_build_options_dc(.{do_output=false});
}
