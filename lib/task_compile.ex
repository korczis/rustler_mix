defmodule Mix.Tasks.Compile.Rustler do
  use Mix.Task

  alias Rustler.Compiler.Messages
  alias Rustler.Compiler.Rustup

  def run(_args) do
    app = Mix.Project.config[:app]
    crates_config = Mix.Project.config[:rustler_crates]
    if !crates_config do
      throw_error(:no_config)
    end
    Enum.map(crates_config, &compile_crate_config(app, &1))
  end

  def priv_path do
    Path.expand("priv")
  end

  def nif_lib_dir do
    path = Path.join(priv_path, "rustler")
    File.mkdir_p!(path)
    path
  end

  def compile_crate_config(app, {id, config}) do
    crate_path = Keyword.get(config, :path)
    Mix.shell.info "Compiling NIF crate #{inspect id} (#{crate_path})..."

    build_mode = Keyword.get(config, :mode, :release)

    compile_command = make_base_command(Keyword.get(config, :cargo, :system))
    |> make_no_default_features_flag(Keyword.get(config, :default_features, true))
    |> make_features_flag(Keyword.get(config, :features, []))
    |> make_build_mode_flag(build_mode)
    |> make_platform_hacks(:os.type)

    crate_full_path = File.cwd! <> crate_path
    target_dir = Mix.Project.build_path <> "/rustler" <> crate_path

    cargo_data = check_crate_env(crate_full_path)
    lib_name = Rustler.TomlParser.get_table_val(cargo_data, ["lib"], "name")
    if lib_name == nil do
      throw_error({:cargo_no_library, crate_path})
    end

    [cmd_bin | args] = compile_command
    compile_return = System.cmd(cmd_bin, args, [
      cd: crate_full_path, 
      env: [{"CARGO_TARGET_DIR", target_dir}], 
      into: IO.stream(:stdio, :line),
    ])

    case compile_return do
      {_, 0} -> nil
      {_, code} -> raise "Rust NIF compile error (rustc exit code #{code})"
    end

    {src_ext, dst_ext} = dll_extension
    compiled_lib = "#{target_dir}/#{Atom.to_string(build_mode)}/lib#{lib_name}.#{src_ext}"
    destination_lib = "#{nif_lib_dir}/lib#{lib_name}.#{dst_ext}"
    File.cp!(compiled_lib, destination_lib)
  end

  defp make_base_command(:system), do: ["cargo", "rustc"]
  defp make_base_command({:bin, path}), do: [path, "rustc"]
  defp make_base_command({:rustup, version}) do
    if Rustup.version == :none do
      throw_error(:rustup_not_installed)
    end
    unless Rustup.version_installed?(version) do
      throw_error({:rust_version_not_installed, version})
    end

    ["rustup", "run", version, "cargo", "rustc"]
  end

  defp make_platform_hacks(args, {:unix, :darwin}) do
    # Fix for https://github.com/hansihe/Rustler/issues/12
    args ++ ["--", "--codegen", "link-args='-flat_namespace -undefined suppress'"]
  end
  defp make_platform_hacks(args, _), do: args

  defp make_no_default_features_flag(args, true), do: args ++ []
  defp make_no_default_features_flag(args, false), do: args ++ ["--no-default-features"]

  defp make_features_flag(args, []), do: args ++ []
  defp make_features_flag(args, flags), do: args ++ ["--features", Enum.join(flags, ",")]

  defp make_build_mode_flag(args, :release), do: args ++ ["--release"]
  defp make_build_mode_flag(args, :debug), do: args ++ []

  def dll_extension do
    case :os.type do
      {:win32, _} -> {"dll", "dll"}
      {:unix, :darwin} -> {"dylib", "so"}
      {:unix, :linux} -> {"so", "so"}
      #{:unix, _} -> {"so", "so"} # Assume .so? Is this a unix thing?
    end
  end

  def throw_error(error_descr) do
    Mix.shell.error Messages.message(error_descr)
    raise "Compilation error"
  end

  def check_crate_env(crate) do
    unless File.dir?(crate) do
      throw_error({:nonexistent_crate_directory, crate})
    end

    cargo_data =
      case File.read("#{crate}/Cargo.toml") do
        {:error, :enoent} ->
          throw_error({:cargo_toml_not_found, crate})
        {:ok, text} ->
          Rustler.TomlParser.parse(text)
      end

    cargo_data
  end

end
