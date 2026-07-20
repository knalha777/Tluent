local httpService = game:GetService("HttpService")

local SaveManager = {} do
	SaveManager.Folder = "FluentSettings"
	SaveManager.Ignore = {}
	SaveManager.AutoSave = true
	SaveManager.AutoSaveConfigName = "__autosave"
	SaveManager._loading = false
	SaveManager._loadPending = false
	SaveManager._initialized = false
	SaveManager._hookedOptions = {}
	SaveManager._autoSaveTimer = nil
	SaveManager.Parser = {
		Toggle = {
			Save = function(idx, object) 
				return { type = "Toggle", idx = idx, value = object.Value } 
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(data.value)
				end
			end,
		},
		Slider = {
			Save = function(idx, object)
				return { type = "Slider", idx = idx, value = tostring(object.Value) }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(tonumber(data.value))
				end
			end,
		},
		Dropdown = {
			Save = function(idx, object)
				return { type = "Dropdown", idx = idx, value = object.Value, multi = object.Multi }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(data.value)
				end
			end,
		},
		Colorpicker = {
			Save = function(idx, object)
				return { type = "Colorpicker", idx = idx, value = object.Value:ToHex(), transparency = object.Transparency }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValueRGB(Color3.fromHex(data.value), data.transparency)
				end
			end,
		},
		Keybind = {
			Save = function(idx, object)
				return { type = "Keybind", idx = idx, mode = object.Mode, key = object.Value }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(data.key, data.mode)
				end
			end,
		},

		Input = {
			Save = function(idx, object)
				return { type = "Input", idx = idx, text = object.Value }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] and type(data.text) == "string" then
					SaveManager.Options[idx]:SetValue(data.text)
				end
			end,
		},
	}

	function SaveManager:SetIgnoreIndexes(list)
		for _, key in next, list do
			self.Ignore[key] = true
		end
	end

	function SaveManager:SetFolder(folder)
		self.Folder = folder;
		self:BuildFolderTree()
	end

	function SaveManager:Save(name)
		if (not name) then
			return false, "no config file is selected"
		end

		local fullPath = self.Folder .. "/settings/" .. name .. ".json"

		local data = {
			objects = {}
		}

		for idx, option in next, SaveManager.Options do
			if not self.Parser[option.Type] then continue end
			if self.Ignore[idx] then continue end

			table.insert(data.objects, self.Parser[option.Type].Save(idx, option))
		end	

		local success, encoded = pcall(httpService.JSONEncode, httpService, data)
		if not success then
			return false, "failed to encode data"
		end

		local writeSuccess, writeErr = pcall(writefile, fullPath, encoded)
		if not writeSuccess then
			return false, "failed to write file: " .. tostring(writeErr)
		end
		return true
	end

	function SaveManager:Load(name)
		if (not name) then
			return false, "no config file is selected"
		end
		
		local file = self.Folder .. "/settings/" .. name .. ".json"
		if not isfile(file) then return false, "invalid file" end

		self._loading = true

		local success, decoded = pcall(httpService.JSONDecode, httpService, readfile(file))
		if not success then
			self._loading = false
			return false, "decode error"
		end

		for _, option in next, decoded.objects do
			if self.Parser[option.type] and not self.Ignore[option.idx] then
				pcall(self.Parser[option.type].Load, option.idx, option)
			end
		end

		self._loading = false
		return true
	end

	function SaveManager:IgnoreThemeSettings()
		self:SetIgnoreIndexes({ 
			"InterfaceTheme", "AcrylicToggle", "TransparentToggle", "MenuKeybind"
		})
	end

	function SaveManager:BuildFolderTree()
		local paths = {
			self.Folder,
			self.Folder .. "/settings"
		}

		for i = 1, #paths do
			local str = paths[i]
			if not isfolder(str) then
				makefolder(str)
			end
		end
	end

	function SaveManager:GetOptions()
		local file = self.Folder .. "/settings/options.json"
		if isfile(file) then
			local success, decoded = pcall(httpService.JSONDecode, httpService, readfile(file))
			if success then
				return decoded
			end
		end

		-- Legacy: migrate from autoload.txt
		local legacyFile = self.Folder .. "/settings/autoload.txt"
		if isfile(legacyFile) then
			return { autoload = readfile(legacyFile), autosave = true }
		end

		return {}
	end

	function SaveManager:SetOption(key, value)
		local options = self:GetOptions()
		options[key] = value

		local success, encoded = pcall(httpService.JSONEncode, httpService, options)
		if success then
			writefile(self.Folder .. "/settings/options.json", encoded)
		end

		-- Clean up legacy autoload.txt if present
		local legacyFile = self.Folder .. "/settings/autoload.txt"
		if isfile(legacyFile) then
			pcall(delfile, legacyFile)
		end
	end

	function SaveManager:RefreshConfigList()
		local list = listfiles(self.Folder .. "/settings")

		local out = {}
		for i = 1, #list do
			local file = list[i]
			if file:sub(-5) == ".json" then
				local name = file:match("[\\/]([^\\/]+)%.json$")
				if name and name ~= "options" and name ~= SaveManager.AutoSaveConfigName then
					table.insert(out, name)
				end
			end
		end
		
		return out
	end

	function SaveManager:SetLibrary(library)
		self.Library = library
        self.Options = library.Options
	end

	function SaveManager:LoadAutoloadConfig()
		-- Legacy method: delegates to AutoLoad() which handles
		-- autoload-first then fallback-to-autosave flow.
		self:AutoLoad()
	end

	function SaveManager:AutoLoad()
		if self._initialized or self._loadPending then
			return
		end

		self._loadPending = true

		-- Defer loading so the UI renders first
		task.defer(function()
			self._loadPending = false

			local options = self:GetOptions()

			-- If autosave is disabled, don't load anything — start fresh
			if options.autosave == false then
				self.AutoSave = false
				self._initialized = true
				return
			end

			-- Try autoload first
			if options.autoload then
				local name = options.autoload
				local configFile = self.Folder .. "/settings/" .. name .. ".json"
				if isfile(configFile) then
					local success = self:Load(name)
					if success then
						self._initialized = true
						self.Library:Notify({
							Title = "Interface",
							Content = "Config loader",
							SubContent = string.format("Auto loaded config %q", name),
							Duration = 7
						})
						return
					end
				end
			end

			-- Fallback to autosave
			local success = self:Load(self.AutoSaveConfigName)
			if success and self.Library then
				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Auto loaded last session",
					Duration = 7
				})
			end

			self._initialized = true
		end)
	end

	function SaveManager:DoAutoSave()
		if not self._initialized or not self.AutoSave or self._loading then return end

		if self._autoSaveTimer then
			pcall(task.cancel, self._autoSaveTimer)
		end

		self._autoSaveTimer = task.delay(0.5, function()
			self._autoSaveTimer = nil
			self:SetupAutoSaveHooks() -- Hook any newly created options
			local success, err = pcall(function()
				self:Save(self.AutoSaveConfigName)
			end)
			if not success and self.Library then
				self.Library:Notify({
					Title = "Auto Save",
					Content = "Failed to auto save",
					SubContent = tostring(err),
					Duration = 7
				})
			end
		end)
	end

	function SaveManager:SetupAutoSaveHooks()
		for idx, option in next, self.Options do
			if self._hookedOptions[idx] then continue end
			if not self.Parser[option.Type] then continue end
			if self.Ignore[idx] then continue end

			local originalSetValue = option.SetValue
			if originalSetValue then
				option.SetValue = function(self_opt, ...)
					originalSetValue(self_opt, ...)
					if not SaveManager._loading then
						pcall(function() SaveManager:DoAutoSave() end)
					end
				end
			end

			local originalCallback = option.Callback
			if originalCallback then
				option.Callback = function(self_opt, ...)
					originalCallback(self_opt, ...)
					if not SaveManager._loading then
						pcall(function() SaveManager:DoAutoSave() end)
					end
				end
			end

			local originalChanged = option.Changed
			if originalChanged then
				option.Changed = function(self_opt, ...)
					originalChanged(self_opt, ...)
					if not SaveManager._loading then
						pcall(function() SaveManager:DoAutoSave() end)
					end
				end
			end

			self._hookedOptions[idx] = true
		end
	end

	function SaveManager:BuildConfigSection(tab)
		assert(self.Library, "Must set SaveManager.Library")

		local section = tab:AddSection("Configuration")

		section:AddInput("SaveManager_ConfigName",    { Title = "Config name" })
		section:AddDropdown("SaveManager_ConfigList", { Title = "Config list", Values = self:RefreshConfigList(), AllowNull = true })

		section:AddButton({
            Title = "Create config",
			Icon = "plus",
            Callback = function()
                local name = SaveManager.Options.SaveManager_ConfigName.Value

                if name:gsub(" ", "") == "" then 
                    return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Invalid config name (empty)",
						Duration = 7
					})
                end

                local success, err = self:Save(name)
                if not success then
                    return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Failed to save config: " .. err,
						Duration = 7
					})
                end

				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format("Created config %q", name),
					Duration = 7
				})

                SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
                SaveManager.Options.SaveManager_ConfigList:SetValue(nil)
            end
        })

        section:AddButton({Title = "Load config", Icon = "download", Callback = function()
			local name = SaveManager.Options.SaveManager_ConfigList.Value
			if not name or name:gsub(" ", "") == "" then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "No config selected to load",
					Duration = 7
				})
			end

			local success, err = self:Load(name)
			if not success then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Failed to load config: " .. err,
					Duration = 7
				})
			end

			self:DoAutoSave() -- Sync loaded state to autosave

			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = string.format("Loaded config %q", name),
				Duration = 7
			})
		end})

		section:AddButton({Title = "Overwrite config", Icon = "upload", Callback = function()
			local name = SaveManager.Options.SaveManager_ConfigList.Value
			if not name or name:gsub(" ", "") == "" then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "No config selected to overwrite",
					Duration = 7
				})
			end

			local success, err = self:Save(name)
			if not success then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Failed to overwrite config: " .. err,
					Duration = 7
				})
			end

			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = string.format("Overwrote config %q", name),
				Duration = 7
			})
		end})

		section:AddButton({Title = "Refresh list", Icon = "rotate-cw", Callback = function()
			SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
			SaveManager.Options.SaveManager_ConfigList:SetValue(nil)
		end})

		section:AddButton({Title = "Delete config", Icon = "gravity:trash-bin", Callback = function()
			local name = SaveManager.Options.SaveManager_ConfigList.Value
			if not name or name:gsub(" ", "") == "" then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "No config selected to delete",
					Duration = 7
				})
			end

			local file = self.Folder .. "/settings/" .. name .. ".json"
			if not isfile(file) then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Config file not found",
					Duration = 7
				})
			end

			local success, err = pcall(delfile, file)
			if not success then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Failed to delete config: " .. tostring(err),
					Duration = 7
				})
			end

			SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
			SaveManager.Options.SaveManager_ConfigList:SetValue(nil)

			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = string.format("Deleted config %q", name),
				Duration = 7
			})
		end})

		local AutoloadButton
		AutoloadButton = section:AddButton({Title = "Set as autoload", Description = "Current autoload config: none", Icon = "star", Callback = function()
			local name = SaveManager.Options.SaveManager_ConfigList.Value
			if not name or name:gsub(" ", "") == "" then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "No config selected to autoload",
					Duration = 7
				})
			end

			self:SetOption("autoload", name)
			AutoloadButton:SetDesc("Current autoload config: " .. name)
			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = string.format("Set %q to auto load", name),
				Duration = 7
			})
		end})

		do
			local options = self:GetOptions()
			if options.autoload then
				AutoloadButton:SetDesc("Current autoload config: " .. options.autoload)
			end
		end

		section:AddButton({Title = "Clear autoload", Icon = "eraser", Callback = function()
			local options = self:GetOptions()
			if options.autoload then
				self:SetOption("autoload", nil)
				AutoloadButton:SetDesc("Current autoload config: none")
				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Cleared autoload config",
					Duration = 7
				})
			end
		end})

		do
			local options = self:GetOptions()
			section:AddToggle("SaveManager_AutoSave", {
				Title = "Auto Save",
				Description = "Automatically saves config on every change",
				Default = options.autosave ~= false,
				Callback = function(Value)
					SaveManager.AutoSave = Value
					SaveManager:SetOption("autosave", Value)
					if Value and SaveManager._initialized then
						SaveManager:DoAutoSave()
					elseif not Value then
						-- Delete autosave session file for a fresh start next time
						local file = SaveManager.Folder .. "/settings/" .. SaveManager.AutoSaveConfigName .. ".json"
						if isfile(file) then
							pcall(delfile, file)
						end
					end
				end
			})
		end

		SaveManager:SetIgnoreIndexes({ "SaveManager_ConfigList", "SaveManager_ConfigName", "SaveManager_AutoSave" })
		SaveManager:SetupAutoSaveHooks()
	end

	SaveManager:BuildFolderTree()
end

return SaveManager
