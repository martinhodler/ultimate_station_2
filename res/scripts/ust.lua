local func = require "ust/func"
local coor = require "ust/coor"
local arc = require "ust/coorarc"
local line = require "ust/coorline"
local quat = require "ust/quaternion"
local general = require "ust/general"
local pipe = require "ust/pipe"
local ust = require "ust_gridization"
local livetext = require "ust/livetext"
local dump = require "luadump"

local math = math
local pi = math.pi
local abs = math.abs
local ceil = math.ceil
local floor = math.floor
local unpack = table.unpack
local min = math.min

ust.infi = 1e8

ust.base = function(id, type)
    return id * 100 + type
end

ust.mixData = function(base, data)
        -- local data = data > 0 and data or (1000 - data)
        return (data < 0 and -base or base) + 1000000 * data
end

ust.slotIds = function(info)
    local base = info.type + info.id * 100
    
    return base, {
        data_pos = {
            ust.mixData(ust.base(info.id, 51), info.pos.x),
            ust.mixData(ust.base(info.id, 52), info.pos.y),
            ust.mixData(ust.base(info.id, 53), info.pos.z)
        },
        data_radius = info.radius and {
            ust.mixData(ust.base(info.id, 54), info.radius > 0 and info.radius % 1000 or -(-info.radius % 1000)),
            ust.mixData(ust.base(info.id, 55), info.radius > 0 and math.floor(info.radius / 1000) or -(math.floor(-info.radius / 1000))),
        } or info.straight and {
            ust.mixData(ust.base(info.id, 56), 0)
        } or {},
        data_geometry = {
            ust.mixData(ust.base(info.id, 57), info.length),
            ust.mixData(ust.base(info.id, 58), info.width)
        },
        data_ref = {
            info.ref and
            ust.mixData(ust.base(info.id, 60),
                (info.ref.left and 1 or 0) +
                (info.ref.right and 2 or 0) +
                (info.ref.next and 4 or 0) +
                (info.ref.prev and 8 or 0)
            ) or
            ust.base(info.id, 60)
        }
    }
end

ust.slotInfo = function(slotId)
        -- Platform/track
        -- 1 ~ 2 : 01 : track 02 platform 03 placeholder
        -- 3 ~ 6 : id
        -- Component
        -- 1 ~ 2 : 20 reserved 21 underpass 22 overpass 23 entry 24 fences
        -- 3 ~ 6 : id
        -- Information
        -- 1 ~ 2 : 50 reserved 51 x 52 y 53 z 54 radius 56 is_straight 57 length 58 width 60 ref
        -- 3 ~ 6 : id
        -- > 6: data
        -- Modifier
        -- 1 ~ 2 : 80 81 radius
        local slotIdAbs = math.abs(slotId)
        local type = slotIdAbs % 100
        local id = (slotIdAbs - type) / 100 % 1000
        local data = slotId > 0 and floor(slotIdAbs / 1000000) or -floor(slotIdAbs / 1000000)
        
        return type, id, data
end

ust.arcPacker = function(pt, vec, length, radius, isRev)
    local nVec = vec:withZ(0):normalized()
    local tVec = coor.xyz(-nVec.y, nVec.x, 0)
    local radius = isRev and -radius or radius
    local o = pt + tVec * radius
    local ar = arc.byOR(o, abs(radius))
    local inf = ar:rad(pt)
    local sup = inf + length / radius
    if isRev then
        inf, sup = sup, inf
    end
    ar = ar:withLimits({
        sup = sup,
        inf = inf
    })
    return function(...)
        local result = func.map({...}, function(dr)
            local dr = isRev and -dr or dr
            return arc.byOR(o, abs(radius + dr), {
                sup = sup,
                inf = inf
            })
        end)
        return ar, unpack(result)
    end
end

local function ungroup(fst, ...)
    local f = {...}
    return function(lst, ...)
        local l = {...}
        return function(result, c)
            if (fst and lst) then
                return ungroup(unpack(f))(unpack(l))(
                    result /
                    (
                    (fst[1] - lst[1]):length2() < (fst[1] - lst[#lst]):length2()
                    and (fst * pipe.range(2, #fst) * pipe.rev() + {fst[1]:avg(lst[1])} + lst * pipe.range(2, #lst))
                    or (fst * pipe.range(2, #fst) * pipe.rev() + {fst[1]:avg(lst[#lst])} + lst * pipe.rev() * pipe.range(2, #lst))
                    ),
                    floor((#fst + #lst) * 0.5)
            )
            else
                return result / c
            end
        end
    end
end

ust.assembleSize = function(lc, rc)
    return {
        lb = lc.i,
        lt = lc.s,
        rb = rc.i,
        rt = rc.s
    }
end

local function mul(m1, m2)
    local m = function(line, col)
        local l = (line - 1) * 3
        return m1[l + 1] * m2[col + 0] + m1[l + 2] * m2[col + 3] + m1[l + 3] * m2[col + 6]
    end
    return {
        m(1, 1), m(1, 2), m(1, 3),
        m(2, 1), m(2, 2), m(2, 3),
        m(3, 1), m(3, 2), m(3, 3),
    }
end

ust.fitModel2D = function(w, h, d, fitTop, fitLeft)
    local s = {
        {
            coor.xy(0, 0),
            coor.xy(fitLeft and w or -w, 0),
            coor.xy(0, fitTop and -h or h),
        },
        {
            coor.xy(0, 0),
            coor.xy(fitLeft and -w or w, 0),
            coor.xy(0, fitTop and h or -h),
        }
    }
    
    local mX = func.map(s,
        function(s) return {
            {s[1].x, s[1].y, 1},
            {s[2].x, s[2].y, 1},
            {s[3].x, s[3].y, 1},
        }
        end)
    
    local mXI = func.map(mX, coor.inv3)
    
    local fitTop = {fitTop, not fitTop}
    local fitLeft = {fitLeft, not fitLeft}
    
    return function(size, mode, z)
        local mXI = mXI[mode and 1 or 2]
        local fitTop = fitTop[mode and 1 or 2]
        local fitLeft = fitLeft[mode and 1 or 2]
        local refZ = size.lt.z
        
        local t = fitTop and
            {
                fitLeft and size.lt or size.rt,
                fitLeft and size.rt or size.lt,
                fitLeft and size.lb or size.rb,
            } or {
                fitLeft and size.lb or size.rb,
                fitLeft and size.rb or size.lb,
                fitLeft and size.lt or size.rt,
            }
        
        local mU = {
            t[1].x, t[1].y, 1,
            t[2].x, t[2].y, 1,
            t[3].x, t[3].y, 1,
        }
        
        local mXi = mul(mXI, mU)
        
        return coor.I() * {
            mXi[1], mXi[2], 0, mXi[3],
            mXi[4], mXi[5], 0, mXi[6],
            0, 0, 1, 0,
            mXi[7], mXi[8], 0, mXi[9]
        } * coor.scaleZ(z and (z / d) or 1) * coor.transZ(refZ)
    end
end

ust.fitModel = function(w, h, d, fitTop, fitLeft)
    local s = {
        {
            coor.xyz(0, 0, 0),
            coor.xyz(fitLeft and w or -w, 0, 0),
            coor.xyz(0, fitTop and -h or h, 0),
            coor.xyz(0, 0, d)
        },
        {
            coor.xyz(0, 0, 0),
            coor.xyz(fitLeft and -w or w, 0, 0),
            coor.xyz(0, fitTop and h or -h, 0),
            coor.xyz(0, 0, d)
        },
    }
    
    local mX = func.map(s, function(s)
        return {
            {s[1].x, s[1].y, s[1].z, 1},
            {s[2].x, s[2].y, s[2].z, 1},
            {s[3].x, s[3].y, s[3].z, 1},
            {s[4].x, s[4].y, s[4].z, 1}
        }
    end)
    
    local mXI = func.map(mX, coor.inv)
    
    local fitTop = {fitTop, not fitTop}
    local fitLeft = {fitLeft, not fitLeft}
    
    return function(size, mode, z)
        local z = z or d
        local mXI = mXI[mode and 1 or 2]
        local fitTop = fitTop[mode and 1 or 2]
        local fitLeft = fitLeft[mode and 1 or 2]
        local t = fitTop and
            {
                fitLeft and size.lt or size.rt,
                fitLeft and size.rt or size.lt,
                fitLeft and size.lb or size.rb,
            } or {
                fitLeft and size.lb or size.rb,
                fitLeft and size.rb or size.lb,
                fitLeft and size.lt or size.rt,
            }
        local mU = {
            t[1].x, t[1].y, t[1].z, 1,
            t[2].x, t[2].y, t[2].z, 1,
            t[3].x, t[3].y, t[3].z, 1,
            t[1].x, t[1].y, t[1].z + z, 1
        }
        
        return mXI * mU
    end
end

ust.interlace = pipe.interlace({"s", "i"})

ust.unitLane = function(f, t, tag, mdl) return
    ((t - f):length2() > 1e-2 and (t - f):length2() < 562500)
        and general.newModel(mdl or "ust/person_lane.mdl", tag, general.mRot(t - f), coor.trans(f))
        or nil
end

ust.stepLane = function(f, t, tag)
    local vec = t - f
    local length = vec:length()
    if (length > 750 or length < 0.1) then return {} end
    local dZ = abs((f - t).z)
    if (length > dZ * 3 or length < 5) then
        return {general.newModel("ust/person_lane.mdl", tag, general.mRot(vec), coor.trans(f))}
    else
        local hVec = vec:withZ(0) / 3
        local fi = f + hVec
        local ti = t - hVec
        return {
            general.newModel("ust/person_lane.mdl", tag, general.mRot(fi - f), coor.trans(f)),
            general.newModel("ust/person_lane.mdl", tag, general.mRot(ti - fi), coor.trans(fi)),
            general.newModel("ust/person_lane.mdl", tag, general.mRot(t - ti), coor.trans(ti))
        }
    end
end

ust.defaultParams = function(params)
    local defParams = params()
    return function(param)
        local function limiter(d, u)
            return function(v) return v and v < u and v or d end
        end
        param.trackType = param.trackType or 0
        param.catenary = param.catenary or 0
        
        func.forEach(
            func.filter(defParams, function(p) return p.key ~= "tramTrack" end),
            function(i)param[i.key] = limiter(i.defaultIndex or 0, #i.values)(param[i.key]) end)
        return param
    end
end

ust.terrain = function(config, ref)
    return pipe.mapn(
        ref.lc,
        ref.rc
    )(function(lc, rc)
        local size = ust.assembleSize(lc, rc)
        return pipe.new / size.lt / size.lb / size.rb / size.rt * pipe.map(coor.vec2Tuple)
    end)
end


function ust.posGen(restTrack, lst, snd, ...)
    if restTrack == 0 then
        if lst and snd then
            return {false, lst, snd, ...}
        else
            return {lst, snd, ...}
        end
    elseif lst == nil then
        return {}
    elseif snd == nil then
        if lst then
            return ust.posGen(restTrack, false, true)
        else
            return ust.posGen(restTrack - 1, true, false)
        end
    else
        if lst and snd then
            return ust.posGen(restTrack, false, lst, snd, ...)
        else
            return ust.posGen(restTrack - 1, true, lst, snd, ...)
        end
    end
end

ust.basePts = function(arc, n)
    local radDelta = (arc.sup - arc.inf) / n
    local rads = func.map(func.seq(0, n), function(i) return arc.inf + i * radDelta end)
    local pts = func.map(rads, function(rad) return arc:pt(rad) end)
    local vecs = func.map(rads, function(rad) return arc:tangent(rad) end)
    return pts, vecs
end

ust.initSlotGrid = function(params, pos)
    if not params.slotGrid[pos.z] then params.slotGrid[pos.z] = {} end
    if not params.slotGrid[pos.z][pos.x] then params.slotGrid[pos.z][pos.x] = {} end
    if not params.slotGrid[pos.z][pos.x][pos.y] then params.slotGrid[pos.z][pos.x][pos.y] = {} end
    if not params.slotGrid[pos.z][pos.x - 1] then params.slotGrid[pos.z][pos.x - 1] = {} end
    if not params.slotGrid[pos.z][pos.x + 1] then params.slotGrid[pos.z][pos.x + 1] = {} end
    if not params.slotGrid[pos.z][pos.x - 1][pos.y] then params.slotGrid[pos.z][pos.x - 1][pos.y] = {} end
    if not params.slotGrid[pos.z][pos.x + 1][pos.y] then params.slotGrid[pos.z][pos.x + 1][pos.y] = {} end
    if not params.slotGrid[pos.z][pos.x][pos.y - 1] then params.slotGrid[pos.z][pos.x][pos.y - 1] = {} end
    if not params.slotGrid[pos.z][pos.x][pos.y + 1] then params.slotGrid[pos.z][pos.x][pos.y + 1] = {} end
end

ust.newTopologySlots = function(params, makeData, pos)
    return function(x, y, transf, octa)
        params.slotGrid[pos.z][x][y].track = {
            id = makeData(1, octa),
            transf = transf,
            type = "ust_track",
            spacing = {0, 0, 0, 0}
        }
        params.slotGrid[pos.z][x][y].platform = {
            id = makeData(2, octa),
            transf = transf,
            type = "ust_platform",
            spacing = {0, 0, 0, 0}
        }
        params.slotGrid[pos.z][x][y].placeholder = {
            id = makeData(3, octa),
            transf = transf,
            type = "ust_placeholder",
            spacing = {0, 0, 0, 0}
        }
    end
end

ust.getTranfs = function(info, pos, width)
    local refArc = info.arcs.center
    if pos == 1 then
        local fwPt = refArc.sup + 0.5 * (refArc.sup - refArc.inf)
        return quat.byVec(coor.xyz(0, 1, 0), refArc:tangent(fwPt)):mRot() * coor.trans(refArc:pt(fwPt))
    elseif pos == 3 then
        local pt = 0.5 * (refArc.sup + refArc.inf)
        local transf = quat.byVec(coor.xyz(0, 1, 0), refArc:tangent(pt)):mRot() * coor.trans(refArc:pt(pt))
        return coor.trans(coor.xyz(width, 0, 0)) * transf
    elseif pos == 5 then
        local bwPt = refArc.inf - 0.5 * (refArc.sup - refArc.inf)
        return quat.byVec(coor.xyz(0, -1, 0), refArc:tangent(bwPt)):mRot() * coor.trans(refArc:pt(bwPt))
    elseif pos == 7 then
        local pt = 0.5 * (refArc.sup + refArc.inf)
        local transf = quat.byVec(coor.xyz(0, 1, 0), refArc:tangent(pt)):mRot() * coor.trans(refArc:pt(pt))
        return coor.trans(coor.xyz(-width, 0, 0)) * transf
    else
        local pt = 0.5 * (refArc.sup + refArc.inf)
        return quat.byVec(coor.xyz(0, 1, 0), refArc:tangent(pt)):mRot() * coor.trans(refArc:pt(pt))
    end
end


ust.classifyComp = function(modules, classified, slotId)
    local type, id, data = ust.slotInfo(slotId)
    
    modules[slotId].info = {
        data = data,
        type = type,
        slotId = slotId,
        id = id
    }
    
    modules[classified[id].slotId].info.comp[type] = true
    
    modules[slotId].makeData = function(type, data)
        return ust.mixData(ust.base(id, type), data)
    end
    
    return type, id, data
end

ust.classifyData = function(modules, classified, slotId)
    local type, id, data = ust.slotInfo(slotId)
    
    classified[id].slot[type] = slotId
    classified[id].info[type] = data
    classified[id].metadata[type] = modules[slotId].metadata
    
    modules[slotId].info = {
        data = data,
        type = type,
        slotId = slotId,
        id = id
    }
    
    return type, id, data
end

ust.preClassify = function(modules, classified, slotId)
    local type, id, data = ust.slotInfo(slotId)
    
    classified[id] = {
        type = type,
        id = id,
        slotId = slotId,
        data = data,
        info = {},
        slot = {},
        metadata = {}
    }
    
    modules[slotId].info = {
        type = type,
        id = id,
        slotId = slotId,
        data = data,
        octa = {false, false, false, false, false, false, false, false},
        comp = {},
        pos = coor.xyz(0, 0, 0),
        width = 5,
        length = 20,
    }
    
    modules[slotId].makeData = function(type, data)
        return ust.mixData(ust.base(id, type), data)
    end
    
    return type, id, data
end


ust.marking = function(result, slotId, params)
    local id = params.modules[slotId].info.id
    local sId = params.classedModules[id].slotId
    local info = params.modules[sId].info
    
    local hRef = params.platformHeight
    local hVec = coor.xyz(0, 0, hRef)
    local hTrans = coor.trans(hVec)
    
    local n = 10
    local ptsL, vecL = ust.basePts(info.arcs.left, n)
    local ptsR, vecR = ust.basePts(info.arcs.right, n)
    local ptsC, vecC = ust.basePts(info.arcs.center, n)
    
    local addText = function(label, transf, f)
        local nameModelsF, width = livetext(2)(label)
        for _, m in ipairs(nameModelsF(function() return (f or coor.I()) * coor.transZ(-0.85) * coor.rotX(-0.5 * pi) * hTrans * transf end)) do
            table.insert(result.models, m)
        end
    end

    for i = 1, 11 do
        addText("⋮", quat.byVec(coor.xyz(0, 1, 0), vecL[i]):mRot() * coor.trans(ptsL[i]), coor.transX(-0.1))
        addText("⋮", quat.byVec(coor.xyz(0, 1, 0), vecR[i]):mRot() * coor.trans(ptsR[i]), coor.transX(-0.1))
    end
    
    for _, i in ipairs({1, 11}) do
        addText("⋯", quat.byVec(coor.xyz(0, 1, 0), vecL[i]):mRot() * coor.trans(ptsL[i]), coor.transX(-0.5))
        addText("⋯", quat.byVec(coor.xyz(0, 1, 0), vecR[i]):mRot() * coor.trans(ptsR[i]), coor.transX(-0.5))
        addText("⋯", quat.byVec(coor.xyz(0, 1, 0), vecC[i]):mRot() * coor.trans(ptsC[i]), coor.transX(-0.5))
    end

    if info.ref.left then
        local refPt = ptsL[6]
        local refVec = vecL[6]
        local transf = quat.byVec(coor.xyz(0, info.pos.y < 0 and -1 or 1, 0), refVec):mRot() * coor.trans(refPt)
        addText("⋘", transf, coor.transX(0.2))
    end
    
    if info.ref.right then
        local refPt = ptsR[6]
        local refVec = vecR[6]
        local transf = quat.byVec(coor.xyz(0, info.pos.y < 0 and 1 or -1, 0), refVec):mRot() * coor.trans(refPt)
        addText("⋘", transf, coor.transX(0.2))
    end
    
    if info.ref.next then
        local i = info.pos.y < 0 and 1 or 11
        local refPt = ptsC[i]
        local refVec = vecC[i]
        local transf = quat.byVec(coor.xyz(info.pos.y < 0 and 1 or -1, 0, 0), refVec):mRot() * coor.trans(refPt)
        addText("⋘", transf, coor.transX(0.2))
    end
    
    if info.ref.prev then
        local i = info.pos.y < 0 and 11 or 1
        local refPt = ptsC[i]
        local refVec = vecC[i]
        local transf = quat.byVec(coor.xyz(info.pos.y < 0 and -1 or 1, 0, 0), refVec):mRot() * coor.trans(refPt)
        addText("⋘", transf, coor.transX(0.2))
    end
end

return ust
