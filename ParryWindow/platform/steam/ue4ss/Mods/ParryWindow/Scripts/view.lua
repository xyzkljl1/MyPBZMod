-- A new instance of a passive game row supplies a concrete UUserWidget class.
-- Only this instance's WidgetTree is replaced; no game UI instance/CDO is edited.
local M = {}
local FIXED_WIDTH, FRAME_WIDTH = 416, 4
local shellPath = '/Game/PBZContent/UI/Settings/Editors/W_SettingsListEntry_Collection_Category.W_SettingsListEntry_Collection_Category_C'
local colors = {
    past = {R=.008,G=.008,B=.008,A=.9}, ahead = {R=1,G=1,B=1,A=1},
    hit = {R=1,G=1,B=1,A=1},
    window = {R=.12,G=.9,B=.015,A=1},
    redWindow = {R=1,G=.04,B=.025,A=1},
    cursor = {R=1,G=.65,B=.06,A=1},
}
local serial = 0
local function valid(o) return o ~= nil and o:IsValid() end
local function native(tree, kind)
    serial = serial + 1
    local object = StaticConstructObject(StaticFindObject('/Script/UMG.' .. kind), tree,
        FName('ParryWindow_' .. kind .. '_' .. serial), 0x40)
    assert(valid(object), 'Cannot construct ' .. kind)
    return object
end
local function place(canvas, child, x, y, w, h)
    local slot = canvas:AddChildToCanvas(child)
    slot:SetPosition({X=x,Y=y}); slot:SetSize({X=w,Y=h})
    return slot
end
local function solid(tree, color)
    local image = native(tree, 'Image')
    -- Use the engine's plain brush; no textures, materials or cooked assets.
    local brush = image.Brush
    brush.DrawAs = 3 -- ESlateBrushDrawType::Image
    image:SetBrush(brush)
    image:SetColorAndOpacity(color)
    return image
end

function M.cleanupStale()
    for _,widget in ipairs(FindAllOf('W_SettingsListEntry_Collection_Category_C') or {}) do
        if valid(widget) and valid(widget.WidgetTree) then
            local root=widget.WidgetTree.RootWidget
            if valid(root) and root:GetFName():ToString():find('ParryWindow_CanvasPanel_',1,true)==1 then
                widget:RemoveFromParent()
            end
        end
    end
end

function M.create(pawn, controller)
    local class = StaticFindObject(shellPath)
    if not valid(class) then class = LoadAsset(shellPath) end
    assert(valid(class), 'Game UI shell is not available')
    local widget = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(pawn, class, controller)
    assert(valid(widget), 'Could not create HUD')
    local self = {widget=widget, rows={}}
    -- Keep the partially created instance available for cleanup if construction fails.
    local ok, err = pcall(function()
        widget.TickFrequency = 0
        widget.bIsFocusable = false
        widget:SetVisibility(3) -- HitTestInvisible, including children.
        local tree = widget.WidgetTree
        assert(valid(tree), 'Game UI shell has no WidgetTree')
        self.tree=tree
        local canvas = native(tree, 'CanvasPanel')
        tree.RootWidget = canvas
        local panel = native(tree, 'CanvasPanel')
        panel:SetRenderTransformPivot({X=.5,Y=.5})
        local anchor = place(canvas, panel, 0, 0, 420, 34)
        anchor:SetAnchors({Minimum={X=.5,Y=.78},Maximum={X=.5,Y=.78}})
        anchor:SetAlignment({X=.5,Y=0})
        local text = native(tree, 'TextBlock')
        text.Font.Size = 13
        text:SetFont(text.Font)
        text:SetShadowOffset({X=1,Y=1})
        text:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
        local textSlot = place(panel,text,0,0,420,20)
        local backgroundSlot = place(panel,solid(tree,colors.past),0,20,420,12)
        local aheadSlot = place(panel,solid(tree,colors.ahead),2,22,416,8)
        local windowsPanel = native(tree,'CanvasPanel')
        local windowsSlot = place(panel,windowsPanel,2,22,416,8)
        local grid = native(tree,'CanvasPanel')
        local gridSlot = place(panel,grid,2,22,416,8)
        local hitsPanel = native(tree,'CanvasPanel')
        local hitsSlot = place(panel,hitsPanel,2,20,416,12)
        -- Draw the pointer last, above windows and expected hits.
        local pointerOutline = place(panel,solid(tree,colors.past),0,19,7,14)
        local pointer = place(panel,solid(tree,colors.cursor),2,18,3,16)
        panel:SetVisibility(1)
        self.rows[1] = {panel=panel,text=text,windowsPanel=windowsPanel,windows={},
            anchor=anchor,textSlot=textSlot,backgroundSlot=backgroundSlot,aheadSlot=aheadSlot,
            windowsSlot=windowsSlot,gridSlot=gridSlot,width=FIXED_WIDTH,
            hitsPanel=hitsPanel,hitsSlot=hitsSlot,hits={},
            pointer=pointer,pointerOutline=pointerOutline,grid=grid,dividers={}}
        widget:AddToViewport(90)
    end)
    if not ok then widget:RemoveFromParent(); error(err,0) end
    return self
end

function M.render(self,sample,mode,offsetX,offsetY,rotate,now)
    local row = self.rows[1]
    if not sample or not sample.totalFrames then
        if row.visible then row.panel:SetVisibility(1); row.visible=false end
        return
    end
    if not row.visible then row.panel:SetVisibility(3); row.visible=true end
    local angle=0
    if rotate then
        row.rotationStart=row.rotationStart or now
        angle=((now-row.rotationStart)*30)%360
    else
        row.rotationStart=nil
    end
    if row.angle~=angle then row.panel:SetRenderTransformAngle(angle); row.angle=angle end
    offsetX,offsetY=offsetX or 0,offsetY or 0
    if row.offsetX~=offsetX or row.offsetY~=offsetY then
        row.anchor:SetPosition({X=offsetX,Y=offsetY})
        row.offsetX,row.offsetY=offsetX,offsetY
    end
    -- Lock the layout at combo start; settings changes apply to the next combo.
    local newCombo=row.comboKey~=sample.key
    if newCombo then
        row.comboKey=sample.key
        local width=mode=='fixed_frame' and sample.totalFrames*FRAME_WIDTH or FIXED_WIDTH
        row.anchor:SetSize({X=width+4,Y=34})
        row.textSlot:SetSize({X=width+4,Y=20})
        row.backgroundSlot:SetSize({X=width+4,Y=12})
        row.aheadSlot:SetSize({X=width,Y=8})
        row.windowsSlot:SetSize({X=width,Y=8})
        row.gridSlot:SetSize({X=width,Y=8})
        row.hitsSlot:SetSize({X=width,Y=12})
        row.width=width
        local count=sample.totalFrames
        local step=width/count
        local gap=math.min(1,step*.25)
        for i=#row.dividers+1,count-1 do
            local widget=solid(self.tree,colors.past)
            row.dividers[i]={widget=widget,slot=place(row.grid,widget,0,0,gap,8)}
        end
        for i,divider in ipairs(row.dividers) do
            divider.widget:SetVisibility(i<count and 3 or 1)
            if i<count then
                divider.slot:SetPosition({X=i*step-gap/2,Y=0})
                divider.slot:SetSize({X=gap,Y=8})
            end
        end
        row.frameSize=step
        -- Expected hit points stay fixed throughout this combo.
        local hits=sample.hits or {}
        for i=#row.hits+1,#hits do
            local hit=solid(self.tree,colors.hit)
            row.hits[i]={widget=hit,slot=place(row.hitsPanel,hit,0,0,1,12)}
        end
        for i,marker in ipairs(row.hits) do
            marker.widget:SetVisibility(hits[i] and 3 or 1)
            if hits[i] then marker.slot:SetPosition({X=hits[i]*step-.5,Y=0}) end
        end
    end
    local windows=sample.windows or {}
    for i=#row.windows+1,#windows do
        local widget=solid(self.tree,colors.window)
        row.windows[i]={widget=widget,slot=place(row.windowsPanel,widget,0,0,1,8)}
    end
    for i,region in ipairs(row.windows) do
        local window=windows[i]
        if not window then
            if region.visible then region.widget:SetVisibility(1); region.visible=false end
        else
            if not region.visible then region.widget:SetVisibility(3); region.visible=true end
            local kind=window.kind or 1
            if region.kind~=kind then
                region.widget:SetColorAndOpacity(kind==2 and colors.redWindow or colors.window)
                region.slot:SetZOrder(kind) -- Keep red visible where the two window types overlap.
                region.kind=kind
            end
            if newCombo or region.first~=window.first or region.last~=window.last then
                region.slot:SetPosition({X=row.frameSize*window.first,Y=0})
                region.slot:SetSize({X=row.frameSize*(window.last-window.first),Y=8})
                region.first,region.last=window.first,window.last
            end
        end
    end
    local x=2+row.width*sample.cursor
    row.pointer:SetPosition({X=x-1.5,Y=18})
    row.pointerOutline:SetPosition({X=x-3.5,Y=19})
    local window=sample.windowFrames and table.concat(sample.windowFrames,', ') or '--'
    local total=sample.totalFrames and string.format('%.0f',sample.totalFrames) or '--'
    local label=window..' / '..total
    if label ~= row.label then row.text:SetText(FText(label)); row.label=label end
end

function M.destroy(self)
    if self and valid(self.widget) then
        self.widget:RemoveFromParent()
    end
end
return M
