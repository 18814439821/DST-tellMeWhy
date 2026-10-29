-- 分阶段探针：由同目录的 stage.lua 里的 PROBE_STAGE 决定装到哪一级。
--
--   0  空壳：什么都不装，只打印一行（用来验证“有这个 mod 也能进游戏”）
--   1  +A   包装全局 SendRPCToServer，只记 rpc == RPC.Say
--   2  +C   ChatHistory.OnSay 包装 + AddChatHistoryListener 监听
--   3  +D   ChatInputScreen 构造时包 OnTextEntered / DoSend / SendChat / Close
--   4  +B   全局 TheNet 透传代理（第一次 Say 后立刻还原）
--   5  +Cq  聊天队列 AddChatLine
--
-- 原则：只读、只打日志，参数原样透传；每级都用 pcall 包住，
-- 任何一级出错只打一行 [probe] FATAL，绝不让异常冒到游戏里。
-- 日志：client_log.txt，行首 [probe]。

local TAG = "[probe]"

-- modmain 跑在受限环境里：实测 rawget 就是 nil，所以标准库一律从 GLOBAL 上取。
local GLOBAL_RAW = GLOBAL
-- _G 上挂着 scripts/strict.lua：读一个当前不存在的键（比如加载期的 ChatHistory）会直接报错，
-- 所以统一走 rawget 的只读代理，G.X 永不抛。
local G = GLOBAL_RAW.setmetatable({}, {
	__index = function(_, k) return GLOBAL_RAW.rawget(GLOBAL_RAW, k) end,
	-- 写也走 rawset：既绕开 strict，又真的落到 _G 上（包装函数必须替换真身，不能只改代理表）
	__newindex = function(_, k, v) GLOBAL_RAW.rawset(GLOBAL_RAW, k, v) end,
})
local unpack = G.unpack or (G.table and G.table.unpack)
local type, tostring, tonumber = G.type, G.tostring, G.tonumber
local pairs, ipairs, select = G.pairs, G.ipairs, G.select
local pcall, print = G.pcall, G.print
local error = G.error
local rawget, getfenv = G.rawget, G.getfenv
local getmetatable, setmetatable = G.getmetatable, G.setmetatable
local string, table, math = G.string, G.table, G.math

-- 幂等标记只在本文件内用（modmain 每次加载只执行一次）。
-- 注意：_G 上挂着 scripts/strict.lua，读写 _G 上不存在的字段会直接报错
-- （"variable 'xxx' is not declared"），所以不能拿 GLOBAL 当草稿纸。
local PROBE = {}

local SEQ = 0

local function Now()
	local f = G.GetTime
	if type(f) ~= "function" then return "?" end
	local ok, t = pcall(f)
	if ok and type(t) == "number" then return string.format("%.3f", t) end
	return "?"
end

local function Text(v)
	if type(v) ~= "string" then return tostring(v) end
	local s = v:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
	return "[" .. s .. "](" .. #v .. "B)"
end

local function Log(tag, ...)
	SEQ = SEQ + 1
	local out = { string.format("%s #%03d t=%s %s", TAG, SEQ, Now(), tostring(tag)) }
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		local tv = type(v)
		if tv == "string" then
			out[#out + 1] = v
		elseif tv == "number" or tv == "boolean" then
			out[#out + 1] = tostring(v)
		elseif v == nil then
			out[#out + 1] = "nil"
		else
			out[#out + 1] = "<" .. tv .. ">"
		end
	end
	print(table.concat(out, " "))
end

local function DumpArgs(tag, ...)
	local n = select("#", ...)
	local a = { ... }
	local out = { "argc=" .. n }
	for i = 1, n do
		local v = a[i]
		if type(v) == "string" then
			out[#out + 1] = i .. "=" .. Text(v)
		else
			out[#out + 1] = i .. "=" .. tostring(v)
		end
	end
	Log(tag, table.concat(out, " "))
	return a, n
end

local function Safe(tag, fn)
	local ok, err = pcall(fn)
	if not ok then Log("FATAL " .. tag, tostring(err)) end
	return ok
end

local function RpcSay()
	local r = G.RPC
	return r and r.Say
end

local SELF_USERID = nil
local function SelfUserid()
	if SELF_USERID then return SELF_USERID end
	local ok, v = pcall(function() return G.TheNet:GetUserID() end)
	if ok and type(v) == "string" and v ~= "" then
		SELF_USERID = v
		return v
	end
	local p = G.ThePlayer
	if p and p.userid then
		SELF_USERID = p.userid
		return p.userid
	end
	return nil
end

local function IsSelf(uid, name)
	local me = SelfUserid()
	if me ~= nil and uid ~= nil then return uid == me end
	if type(name) == "string" then
		local p = G.ThePlayer
		if p then
			local ok, n = pcall(function() return p:GetDisplayName() end)
			if ok and n == name then return true end
		end
	end
	return false
end

local function BuildInfo()
	local sim = G.TheSim
	if not sim then return "no-TheSim" end
	local names = { "GetBuild", "GetBuildDate", "GetVersion" }
	local out = {}
	for i = 1, #names do
		local n = names[i]
		local ok, v = pcall(function() return sim[n](sim) end)
		out[#out + 1] = n .. "=" .. tostring(ok and v or "ERR")
	end
	return table.concat(out, ",")
end

local function ListMethods(obj, tag)
	local cls = getmetatable(obj)
	if type(cls) ~= "table" then return end
	local names = {}
	for k, v in pairs(cls) do
		if type(k) == "string" and type(v) == "function" then
			if k:find("Enter", 1, true) or k:find("Send", 1, true) or k:find("Say", 1, true)
				or k:find("Submit", 1, true) or k:find("Chat", 1, true) or k:find("Close", 1, true) then
				names[#names + 1] = k
			end
		end
	end
	table.sort(names)
	Log(tag, "n=" .. #names, table.concat(names, ","))
end

---------------------------------------------------------------------------
-- 阶段 1：A —— 全局 SendRPCToServer
---------------------------------------------------------------------------
local function InstallRPC()
	if PROBE.A then return end
	local old = G.SendRPCToServer
	if type(old) ~= "function" then
		Log("A missing (SendRPCToServer=" .. type(old) .. ")")
		return
	end
	G.SendRPCToServer = function(rpc, ...)
		local say = RpcSay()
		if say ~= nil and rpc == say then
			DumpArgs("A.rpc RPC.Say", ...)
		end
		return old(rpc, ...)
	end
	PROBE.A = true
	Log("A wrapped", "RPC.Say=" .. tostring(RpcSay()))
end

---------------------------------------------------------------------------
-- 阶段 2：C —— ChatHistory（接收侧）
---------------------------------------------------------------------------
local function InstallChatHistory()
	local CH = G.ChatHistory
	if type(CH) ~= "table" then
		Log("C missing (ChatHistory=" .. type(CH) .. ")")
		return
	end
	if PROBE.CH ~= CH then
		PROBE.CH = CH
		PROBE.C_listener = nil
		PROBE.C_onsay = nil
	end

	if not PROBE.C_listener and type(CH.AddChatHistoryListener) == "function" then
		local ok, err = pcall(function()
			CH:AddChatHistoryListener(function(msg)
				if type(msg) ~= "table" then return end
				local keys = {}
				for k in pairs(msg) do keys[#keys + 1] = tostring(k) end
				table.sort(keys)
				Log("C.listener",
					"is_self=" .. tostring(IsSelf(msg.sender_userid, msg.sender_name)),
					"userid=" .. tostring(msg.sender_userid),
					"name=" .. Text(msg.sender_name),
					"whisper=" .. tostring(msg.whisper),
					"localonly=" .. tostring(msg.localonly),
					"msg=" .. Text(msg.message),
					"keys=" .. table.concat(keys, ","))
			end)
		end)
		PROBE.C_listener = ok
		Log("C.listener install", tostring(ok), tostring(err))
	end

	if not PROBE.C_onsay and type(CH.OnSay) == "function" then
		local old = CH.OnSay
		CH.OnSay = function(self, ...)
			local a, n = DumpArgs("C.onsay", ...)
			Log("C.onsay.decoded",
				"is_self=" .. tostring(IsSelf(a[2], a[4])),
				"userid=" .. tostring(a[2]),
				"name=" .. Text(a[4]),
				"prefab=" .. tostring(a[5]),
				"msg=" .. Text(a[6]),
				"whisper=" .. tostring(a[8]))
			return old(self, unpack(a, 1, n))
		end
		PROBE.C_onsay = true
		Log("C.onsay wrapped")
	end
end

---------------------------------------------------------------------------
-- 阶段 3：D —— ChatInputScreen 发送前
---------------------------------------------------------------------------
-- Close 在“取消输入”时也会触发，不能用来判“已发送”，所以不挂它。
local D_METHODS = { "OnTextEntered", "DoSend", "SendChat" }

local function InstallChatInput()
	if PROBE.D_hooked then return end
	PROBE.D_hooked = true
	Safe("D.hook", function()
		AddClassPostConstruct("screens/chatinputscreen", function(self)
			Log("D.screen",
				"whisper=" .. tostring(self.whisper),
				"has_chat_edit=" .. tostring(self.chat_edit ~= nil),
				"has_text=" .. tostring(self.text ~= nil))
			ListMethods(self, "D.class")
			Safe("C.retry", InstallChatHistory)
			local cls = getmetatable(self)
			if type(cls) ~= "table" then return end
			for i = 1, #D_METHODS do
				local name = D_METHODS[i]
				if not PROBE["D_" .. name] and type(cls[name]) == "function" then
					local old = cls[name]
					cls[name] = function(inst, ...)
						local txt
						local te = inst.chat_edit or inst.text
						if te and te.GetString then
							local ok, s = pcall(function() return te:GetString() end)
							if ok then txt = s end
						end
						Log("D.chatinput " .. name,
							"whisper=" .. tostring(inst.whisper),
							"text=" .. Text(txt),
							"argc=" .. select("#", ...))
						return old(inst, ...)
					end
					PROBE["D_" .. name] = true
					Log("D.wrapped", name)
				end
			end
		end)
	end)
end

---------------------------------------------------------------------------
-- 阶段 4：B —— TheNet 透传代理
---------------------------------------------------------------------------
local function InstallTheNetProxy()
	if PROBE.B_done then return end
	PROBE.B_done = true

	local real = G.TheNet
	if real == nil then
		Log("B missing (TheNet nil)")
		return
	end

	if type(real) == "table" then
		local old = real.Say
		if type(old) == "function" then
			real.Say = function(inst, ...)
				Log("B.thenet Say HIT (table)", "argc=" .. select("#", ...), "a1=" .. Text((...)))
				return old(inst, ...)
			end
			Log("B table patched")
		else
			Log("B missing (table without Say)")
		end
		return
	end

	if type(real) ~= "userdata" then
		Log("B missing (TheNet=" .. type(real) .. ")")
		return
	end

	local proxy
	local cache = {}

	local function Restore(reason)
		if G.TheNet == proxy then
			G.TheNet = real
			Log("B restored", tostring(reason))
		end
	end

	local function MakeForwarder(name, fn)
		return function(inst, ...)
			local a = { ... }
			local n = select("#", ...)
			if name == "Say" then
				Log("B.thenet Say HIT", "argc=" .. n, "a1=" .. Text(a[1]), "a2=" .. tostring(a[2]))
			elseif name == "SendRPCToServer" then
				local say = RpcSay()
				if say ~= nil and a[1] == say then
					Log("B.thenet SendRPCToServer(Say) HIT", "argc=" .. n, "a2=" .. Text(a[2]), "a3=" .. tostring(a[3]))
				end
			end
			local ok, err = pcall(function() return fn(real, unpack(a, 1, n)) end)
			if name == "Say" then Restore("after first Say") end
			if not ok then error(err, 0) end
		end
	end

	proxy = setmetatable({}, {
		__index = function(_, k)
			local v = real[k]
			if type(v) == "function" then
				if cache[k] == nil then cache[k] = MakeForwarder(k, v) end
				return cache[k]
			end
			return v
		end,
		__newindex = function(_, k, v) real[k] = v end,
		__tostring = function() return "TheNet(probe proxy)" end,
	})

	G.TheNet = proxy
	Log("B proxy installed (auto-restore after first Say)")
end

---------------------------------------------------------------------------
-- 阶段 5：Cq —— 聊天队列 AddChatLine
---------------------------------------------------------------------------
local function WrapClassMethod(path, tag, method)
	Safe(tag .. ".hook", function()
		AddClassPostConstruct(path, function(self)
			if PROBE[tag] then return end
			local cls = getmetatable(self)
			if type(cls) ~= "table" then return end
			local old = cls[method]
			if type(old) ~= "function" then
				Log(tag .. ".missing", path .. "." .. method)
				return
			end
			PROBE[tag] = true
			cls[method] = function(inst, ...)
				DumpArgs(tag .. " " .. path, ...)
				return old(inst, ...)
			end
			Log(tag .. ".wrapped", path .. "." .. method)
		end)
	end)
end

local function InstallChatQueue()
	WrapClassMethod("widgets/redux/scrollablechatqueue", "C.chatqueue", "AddChatLine")
	WrapClassMethod("widgets/chatqueue", "C.chatqueue.legacy", "AddChatLine")
end

---------------------------------------------------------------------------
-- 读 stage.lua
---------------------------------------------------------------------------
-- stage.lua 里只有一行 "PROBE_STAGE = N"；modimport 进来的文件和 modmain 共用同一个 env，
-- 所以它写进去的就是本函数里能读到的字段。用 rawget 读，绕开任何元表。
local DEFAULT_STAGE = 3   -- stage.lua 缺失/写坏时的兜底级别
local function ReadStage()
	if type(rawget) ~= "function" or type(getfenv) ~= "function" then
		return DEFAULT_STAGE, "missing-libs"
	end
	local ok, err = pcall(modimport, "stage.lua")
	if not ok then
		Log("stage import failed", tostring(err))
		return DEFAULT_STAGE, "default"
	end
	local n = rawget(getfenv(1), "PROBE_STAGE")
	if type(n) ~= "number" then
		Log("stage bad value", tostring(n))
		return DEFAULT_STAGE, "default"
	end
	n = math.floor(n)
	if n < 0 or n > 5 then
		Log("stage out of range", tostring(n))
		return DEFAULT_STAGE, "default"
	end
	return n, "ok"
end

local STAGE, STAGE_SRC = ReadStage()

Log("boot",
	"stage=" .. STAGE,
	"stage_src=" .. STAGE_SRC,
	"build=" .. BuildInfo(),
	"TheNet=" .. type(G.TheNet),
	"RPC.Say=" .. tostring(RpcSay()),
	"SendRPCToServer=" .. type(G.SendRPCToServer),
	"ChatHistory=" .. type(G.ChatHistory))

if STAGE >= 1 then Safe("stage1.A", InstallRPC) end
if STAGE >= 2 then Safe("stage2.C", InstallChatHistory) end
if STAGE >= 3 then Safe("stage3.D", InstallChatInput) end
if STAGE >= 4 then Safe("stage4.B", InstallTheNetProxy) end
if STAGE >= 5 then Safe("stage5.Cq", InstallChatQueue) end

AddGamePostInit(function()
	PROBE.in_game = true
	Log("post_game_init", "self_userid=" .. tostring(SelfUserid()), "stage=" .. STAGE)
	if STAGE >= 1 then Safe("stage1.A", InstallRPC) end
	if STAGE >= 2 then Safe("stage2.C", InstallChatHistory) end
	if STAGE >= 3 then Safe("stage3.D", InstallChatInput) end
	if STAGE >= 4 then Safe("stage4.B", InstallTheNetProxy) end
	if STAGE >= 5 then Safe("stage5.Cq", InstallChatQueue) end
end)

AddPlayerPostInit(function(inst)
	PROBE.in_game = true
	if STAGE >= 2 then Safe("stage2.C", InstallChatHistory) end
end)

if STAGE == 0 then
	Log("stage0 done (empty shell, nothing hooked)")
end
