local roundStartTime = CurTime()
hook.Add("PreRestartRound", D3bot.BotHooksId.."PreRestartRoundSupervisor", function() roundStartTime, D3bot.NodeZombiesCountAddition = CurTime(), nil end)

function D3bot.GetDesiredBotCount()
	local wave = math.max(1, GAMEMODE:GetWave())
	local minutes = (CurTime() - roundStartTime) / 60
	local allowedTotal = game.MaxPlayers() - #player.GetAll() - 2
	local mapParams = D3bot.MapNavMesh.Params
	local zombieFormula = ((mapParams.ZPP or D3bot.ZombiesPerPlayer) + (mapParams.ZPPW or D3bot.ZombiesPerPlayerWave) * wave) * #player.GetHumans() + (mapParams.ZPM or D3bot.ZombiesPerMinute) * minutes + (mapParams.ZPW or D3bot.ZombiesPerWave) * wave
	local zombiesCount = math.Clamp(
		math.ceil(math.min(zombieFormula, (mapParams.ZPPM or D3bot.ZombiesPerPlayerMax) * #player.GetHumans()) + D3bot.ZombiesCountAddition + (mapParams.BotMod or 0) + (D3bot.NodeZombiesCountAddition or 0)),
		0,
		allowedTotal)
	local survivorFormula = (mapParams.SPP or D3bot.SurvivorsPerPlayer) * #player.GetHumans()
	local survivorsCount = math.Clamp(
		math.ceil(survivorFormula + D3bot.SurvivorCountAddition + (mapParams.SCA or 0)),
		0,
		math.max(allowedTotal - zombiesCount, 0))
	return zombiesCount, (GAMEMODE.ZombieEscape or GAMEMODE.ObjectiveMap) and 0 or survivorsCount
end

function D3bot.MaintainBotRoles()
	if #player.GetHumans() == 0 then return end
	local desiredCountByTeam = {}
	desiredCountByTeam[TEAM_UNDEAD], desiredCountByTeam[TEAM_SURVIVOR] = D3bot.GetDesiredBotCount()
	local bots = player.GetBots()
	local botsByTeam = {}
	for k, v in ipairs(bots) do
		local team = v:Team()
		botsByTeam[team] = botsByTeam[team] or {}
		table.insert(botsByTeam[team], v)
	end
	local players = player.GetAll()
	local playersByTeam = {}
	for k, v in ipairs(players) do
		local team = v:Team()
		playersByTeam[team] = playersByTeam[team] or {}
		table.insert(playersByTeam[team], v)
	end
	
	-- Sort by frags and being boss zombie
	if botsByTeam[TEAM_UNDEAD] then
		table.sort(botsByTeam[TEAM_UNDEAD], function(a, b) return (a:GetZombieClassTable().Boss and 1 or 0) > (b:GetZombieClassTable().Boss and 1 or 0) end)
	end
	for team, botByTeam in pairs(botsByTeam) do
		table.sort(botByTeam, function(a, b) return a:Frags() < b:Frags() end)
	end
	
	-- Stop managing survivor bots, after round started. Except on ZE or obj maps, where survivors are managed to be 0
	if GAMEMODE:GetWave() > 0 and not GAMEMODE.ZombieEscape and not GAMEMODE.ObjectiveMap then
		desiredCountByTeam[TEAM_SURVIVOR] = nil
	end
	
	-- Move (kill) survivors to undead if possible
	if desiredCountByTeam[TEAM_SURVIVOR] and desiredCountByTeam[TEAM_UNDEAD] then
		if #(playersByTeam[TEAM_SURVIVOR] or {}) > desiredCountByTeam[TEAM_SURVIVOR] and #(playersByTeam[TEAM_UNDEAD] or {}) < desiredCountByTeam[TEAM_UNDEAD] and botsByTeam[TEAM_SURVIVOR] then
			local randomBot = table.remove(botsByTeam[TEAM_SURVIVOR], 1)
			randomBot:StripWeapons()
			randomBot:KillSilent()
			return
		end
	end
	-- Add bots out of managed teams to maintain desired counts
	for team, desiredCount in pairs(desiredCountByTeam) do
		if #(playersByTeam[team] or {}) < desiredCount then
			RunConsoleCommand("bot")
			--local bot = player.CreateNextBot("Test")
			D3bot.SpawnAsZombie = team == TEAM_UNDEAD
			return
		end
	end
	-- Remove bots out of managed teams to maintain desired counts
	for team, desiredCount in pairs(desiredCountByTeam) do
		if #(playersByTeam[team] or {}) > desiredCount and botsByTeam[team] then
			local randomBot = table.remove(botsByTeam[team], 1)
			randomBot:StripWeapons()
			return randomBot and randomBot:Kick(D3bot.BotKickReason)
		end
	end
	-- Remove bots out of non managed teams if the server is getting too full
	local allowedTotal = game.MaxPlayers() - 2
	if player.GetCount() > allowedTotal then
		for team, desiredCount in pairs(desiredCountByTeam) do
			if not desiredCountByTeam[team] and botsByTeam[team] then
				local randomBot = table.remove(botsByTeam[team], 1)
				randomBot:StripWeapons()
				return randomBot and randomBot:Kick(D3bot.BotKickReason)
			end
		end
	end
end

local NextNodeDamage = CurTime()
local NextMaintainBotRoles = CurTime()
function D3bot.SupervisorThinkFunction()
	if NextMaintainBotRoles < CurTime() then
		NextMaintainBotRoles = CurTime() + 1
		D3bot.MaintainBotRoles()
	end
	if (NextNodeDamage or 0) < CurTime() then
		NextNodeDamage = CurTime() + 2
		D3bot.DoNodeTrigger()
	end
end

function D3bot.DoNodeTrigger()
	local players = D3bot.RemoveObsDeadTgts(player.GetAll())
	players = D3bot.From(players):Where(function(k, v) return v:Team() ~= TEAM_UNDEAD end).R
	local ents = table.Add(players, D3bot.GetEntsOfClss(D3bot.NodeDamageEnts))
	for i, ent in pairs(ents) do
		local nodeOrNil = D3bot.MapNavMesh:GetNearestNodeOrNil(ent:GetPos()) -- TODO: Don't call GetNearestNodeOrNil that often
		if nodeOrNil then
			if type(nodeOrNil.Params.DMGPerSecond) == "number" and nodeOrNil.Params.DMGPerSecond > 0 then
				ent:TakeDamage(nodeOrNil.Params.DMGPerSecond*2, game.GetWorld(), game.GetWorld())
			end
			if ent:IsPlayer() and not ent:IsBot() and nodeOrNil.Params.BotMod then
				D3bot.NodeZombiesCountAddition = nodeOrNil.Params.BotMod
			end
		end
	end
end

-- TODO: Detect situations and coordinate bots accordingly (Attacking cades, hunt down runners, spawncamping prevention)
-- TODO: If needed force one bot to flesh creeper and let him build a nest at a good place