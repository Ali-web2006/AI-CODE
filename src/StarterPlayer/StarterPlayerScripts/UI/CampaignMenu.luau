--!strict
--[[
	CampaignMenu — a popover with campaign-level actions: save, load, and (in development builds
	only) advancing to the next month. It states plainly where saves go: a persistent DataStore,
	server memory that disappears when the server closes, or nowhere when storage is unavailable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts
local Commands = Protocol.Commands

local CampaignMenu = {}

export type CampaignMenu = {
	toggle: (anchor: GuiObject) -> (),
	close: () -> (),
}

function CampaignMenu.storageDescription(session: { [string]: any }): string
	local persistence = session.persistence or {}
	if not persistence.available then
		return `Saving unavailable: {persistence.reason or "no storage"}.`
	elseif persistence.persistent then
		return `Saves go to {persistence.backendName} and persist between sessions.`
	end
	return `Saves are kept in server memory only and are lost when this server closes ({persistence.reason or "DataStore unavailable"}).`
end

-- Describes the host's save slot from a GetSaveInfo result.
function CampaignMenu.describeSave(result: { [string]: any }): string
	if not result.ok then
		return result.message
	end
	local data = result.data or {}
	if not data.exists then
		return "No saved campaign yet."
	end
	local summary = data.summary or {}
	local house = summary.hostHouseId and Content.houses[summary.hostHouseId]
	local date = if summary.date and CalendarDate.isValid(summary.date) then CalendarDate.format(summary.date) else "unknown date"
	return `Last save: {date}{if house then ` as {house.name}` else ""} (revision {data.revision or "?"}).`
end

function CampaignMenu.mount(parent: Frame, ctx: UIContext.Context, getScale: () -> number): CampaignMenu
	local store = ctx.store
	local popover = UI.create("Frame", {
		Name = "CampaignMenu",
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Parchment,
		Visible = false,
		Active = true,
		ZIndex = 40,
		Parent = parent,
	})
	UI.corner(popover)
	UI.stroke(popover, Colors.Gold, 1.5)
	UI.padding(popover, 12)
	UI.list(popover, "vertical", 8)

	local saveInfoLabel: TextLabel? = nil

	local function refreshSaveInfo()
		local label = saveInfoLabel
		if not label then
			return
		end
		label.Text = "Checking the save slot..."
		ctx.run(Commands.GetSaveInfo, nil, "saveinfo", function(result)
			if label.Parent then
				label.Text = CampaignMenu.describeSave(result)
			end
		end)
	end

	local function render()
		for _, child in popover:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") and not child:IsA("UICorner") and not child:IsA("UIStroke") then
				child:Destroy()
			end
		end
		local session = store.session
		local isHost = session.isHost == true
		local available = session.persistence and session.persistence.available

		UI.label({ text = "Campaign", font = Fonts.Heading, size = Theme.TextSize.Large, order = 1, parent = popover })
		UI.label({ text = CampaignMenu.storageDescription(session), wrap = true, size = Theme.TextSize.Small, color = Colors.InkMuted, order = 2, parent = popover })
		saveInfoLabel = UI.label({ text = "", wrap = true, size = Theme.TextSize.Small, order = 3, parent = popover })

		local saveButton = UI.button({
			text = "Save campaign",
			variant = "primary",
			order = 4,
			parent = popover,
			onActivated = function()
				ctx.run(Commands.SaveCampaign, nil, "save", function()
					refreshSaveInfo()
				end)
			end,
		})
		local loadButton = UI.button({
			text = "Load last save",
			variant = "secondary",
			order = 5,
			parent = popover,
			onActivated = function()
				ctx.run(Commands.LoadCampaign, nil, "load")
				popover.Visible = false
			end,
		})
		if not available then
			UI.setEnabled(saveButton, false, "No storage backend is available.")
			UI.setEnabled(loadButton, false, "No storage backend is available.")
		elseif not isHost then
			UI.setEnabled(saveButton, false, "Only the host can save the shared campaign.")
			UI.setEnabled(loadButton, false, "Only the host can load a campaign.")
		else
			Tooltip.setText(loadButton, "Replaces the running campaign for every player with your last save.")
		end

		if session.environment == "development" then
			local devButton = UI.button({
				text = "DEV: advance to next month",
				variant = "ghost",
				order = 6,
				parent = popover,
				onActivated = function()
					ctx.run(Commands.DebugAdvanceMonth, nil, "devmonth")
				end,
			})
			if isHost then
				Tooltip.setText(devButton, "Development builds only: runs the real clock day by day until the month ends.")
			else
				UI.setEnabled(devButton, false, "Only the host can use debug commands.")
			end
		end

		UI.button({
			text = "Close",
			variant = "ghost",
			order = 7,
			parent = popover,
			onActivated = function()
				popover.Visible = false
			end,
		})
		if available then
			refreshSaveInfo()
		else
			(saveInfoLabel :: TextLabel).Visible = false
		end
	end

	local menu: CampaignMenu = {
		toggle = function(anchor: GuiObject)
			if popover.Visible then
				popover.Visible = false
				return
			end
			-- Right-align under the anchor. Absolute coordinates are screen pixels; the popover is
			-- positioned in the parent's virtual (pre-UIScale) coordinates.
			local parentFrame = popover.Parent :: GuiObject
			local relative = (anchor.AbsolutePosition + anchor.AbsoluteSize - parentFrame.AbsolutePosition) / getScale()
			popover.Position = UDim2.fromOffset(relative.X, relative.Y + 6)
			render()
			popover.Visible = true
		end,
		close = function()
			popover.Visible = false
		end,
	}
	return menu
end

return CampaignMenu
