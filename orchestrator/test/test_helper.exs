exclude = if :os.type() == {:unix, :darwin}, do: [], else: [:macos]
ExUnit.start(exclude: exclude)
