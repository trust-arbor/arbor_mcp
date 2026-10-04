# Run without loading any package dependencies. Hex metadata is Erlang terms,
# so consult it rather than applying a partial text parser.
Mix.start()
Mix.env(:prod)

projects =
  for directory <- System.argv() do
    {:ok, terms} =
      :file.consult(String.to_charlist(Path.join(directory, ".archive-metadata.config")))

    metadata = Map.new(terms)
    app = String.to_atom(metadata["app"])

    Mix.Project.in_project(app, directory, fn _ ->
      config = Mix.Project.config()
      version = config[:version]
      source = File.read!("mix.exs")
      [[_matched, literal]] = Regex.scan(~r/@version "([^"]+)"/, source)
      true = version == literal and version == metadata["version"]
      true = version == System.fetch_env!("ARCHIVE_EXPECTED_VERSION")
      true = metadata["name"] == Atom.to_string(app)
      true = config[:app] == app
      false = Enum.any?(metadata["requirements"], &(Map.new(&1)["name"] == "ex_doc"))

      prerelease? = Version.parse!(version).pre != []
      requirement = if prerelease?, do: "~> #{version}", else: "~> 2.0"

      for dependency <- metadata["requirements"],
          dependency = Map.new(dependency),
          dependency["name"] in ["arbor_rpc", "arbor_acp"] do
        true = dependency["requirement"] == requirement
        true = dependency["optional"] == false
        dependency_app = String.to_atom(dependency["app"])

        declared = Enum.find(config[:deps], &(elem(&1, 0) == dependency_app))
        true = elem(declared, 1) == requirement
        options = if tuple_size(declared) == 3, do: elem(declared, 2), else: []
        false = Keyword.has_key?(options, :path)
        true = Version.match?(version, requirement)
        false = Version.match?("1.9.9", requirement)
        false = Version.match?("3.0.0", requirement)
        true = Version.match?("2.1.0", requirement) == not prerelease?
        true = Version.match?("2.0.0-dev", requirement) == (version == "2.0.0-dev")
        true = Version.match?("2.0.0-rc.999999", requirement) == prerelease?
      end

      {:ex_doc, "~> 0.40", doc_options} = Enum.find(config[:deps], &(elem(&1, 0) == :ex_doc))
      :dev = doc_options[:only]
      false = doc_options[:runtime]
      false = Keyword.has_key?(doc_options, :path)

      ref = if app == :arbor_mcp, do: "v#{version}", else: "#{app}-v#{version}"
      true = config[:docs][:source_ref] == ref

      if app != :arbor_mcp do
        expected =
          "https://github.com/trust-arbor/arbor_acp/blob/#{ref}/packages/#{app}/%{path}#L%{line}"

        true = config[:docs][:source_url_pattern] == expected
      end

      IO.puts("Verified #{app}: literal/Hex #{version}, source ref #{ref}")
      version
    end)
  end

1 = projects |> Enum.uniq() |> length()
