param(
    [string]$Prompt,
    [string]$Question,
    [switch]$Diagnose,
    [string]$Model = 'qwen3:8b',
    [string]$OllamaBaseUrl = 'http://127.0.0.1:11434',
    [switch]$Execute,
    [switch]$TestConnection
)

$ErrorActionPreference = 'Stop'

# Deterministic local settings knowledge base + read-only diagnostics
# (asa_claude_package/). Separate from the write pipeline below: it can
# never expand what settings/actions this engine is allowed to apply.
. (Join-Path $PSScriptRoot 'ASA-AI-Knowledge.ps1')

# The Ollama/model path is proposal-only and never receives filesystem access.
# Deterministic helpers below may apply only allow-listed settings to two fixed INI files.
$script:AllowedSettings = [ordered]@{
    XPMultiplier                         = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=100.0; Note='Overall XP multiplier.' }
    HarvestAmountMultiplier              = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=100.0; Note='Resources gathered per hit.' }
    TamingSpeedMultiplier                = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=100.0; Note='Higher makes taming complete faster.' }
    PassiveTameIntervalMultiplier        = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.05; Max=10.0;  Note='Lower shortens the wait between passive tame feeds.' }
    PlayerResistanceMultiplier           = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=5.0;   Note='Lower means players take less incoming damage.' }
    ResourcesRespawnPeriodMultiplier     = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower makes resources respawn sooner.' }
    PlayerCharacterFoodDrainMultiplier   = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower means hunger drains more slowly.' }
    PlayerCharacterWaterDrainMultiplier  = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower means thirst drains more slowly.' }
    MatingIntervalMultiplier             = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.01; Max=10.0;  Note='Lower lets creatures mate again sooner.' }
    MatingSpeedMultiplier                = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher fills the mating progress bar faster.' }
    EggHatchSpeedMultiplier              = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher makes fertilized eggs hatch faster.' }
    BabyMatureSpeedMultiplier            = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher makes babies mature faster.' }
    BabyCuddleIntervalMultiplier         = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.01; Max=10.0;  Note='Lower requests imprint care more often.' }
    BabyImprintAmountMultiplier          = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher gives more imprint progress per care.' }
    CropGrowthSpeedMultiplier            = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1;  Max=100.0; Note='Higher makes crops grow faster.' }
    DayCycleSpeedScale                   = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Higher makes the whole day/night cycle pass faster.' }
    DayTimeSpeedScale                    = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Lower makes daylight last longer.' }
    NightTimeSpeedScale                  = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1;  Max=10.0;  Note='Higher makes nighttime pass faster.' }
    OverrideOfficialDifficulty           = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.2;  Max=5.0;   Note='Controls max wild dino level, roughly level = value x 30. 5.0 is official-server max (level 150).' }
    SupplyCrateLootQualityMultiplier     = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.5;  Max=10.0;  Note='Higher gives better-quality loot in supply crates (does not change how often crates spawn).' }
    AutoSavePeriodMinutes                = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=1;    Max=60.0;  Note='Lower saves the world more often (more crash protection, slightly more disk activity).' }
    'PerLevelStatsMultiplier_DinoWild[0]'   = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=3.0; Note='Wild dino health gained per level. Lower makes high-level wild dinos less tanky.' }
    'PerLevelStatsMultiplier_DinoWild[8]'   = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=3.0; Note='Wild dino melee damage gained per level. Lower makes high-level wild dinos hit less hard.' }
    'PerLevelStatsMultiplier_Player[8]'     = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=5.0; Note='Player melee damage gained per level put into Melee Damage.' }
    'PerLevelStatsMultiplier_Player[9]'     = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=5.0; Note='Player movement speed gained per level put into Speed.' }
    'PerLevelStatsMultiplier_Player[11]'    = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=5.0; Note='Player crafting-speed stat gained per level put into Crafting Speed.' }
    DinoCountMultiplier                     = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1; Max=5.0; Note='How many wild dinos spawn on the map overall. 1.0 is standard density.' }
    DinoCharacterHealthRecoveryMultiplier    = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1; Max=20.0; Note='How fast dinos regenerate lost health over time. Affects wild and tamed dinos together.' }
    'PerLevelStatsMultiplier_DinoTamed[0]'  = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=5.0; Note='Tamed dino health gained per level.' }
    'PerLevelStatsMultiplier_DinoTamed[8]'  = @{ TargetFile='Game.ini'; Section='[/Script/ShooterGame.ShooterGameMode]'; Min=0.1; Max=5.0; Note='Tamed dino melee damage gained per level.' }
    WantsEqualLevels                     = @{ TargetFile='GameUserSettings.ini'; Section='[CustomLevelDistrib]'; Type='Boolean'; Note='Custom Dino Levels mod: every wild dino level equally likely. Mutually exclusive with WantsHighLevels.' }
    WantsHighLevels                       = @{ TargetFile='GameUserSettings.ini'; Section='[CustomLevelDistrib]'; Type='Boolean'; Note='Custom Dino Levels mod: skews wild dino spawns toward the higher end of the level range. Mutually exclusive with WantsEqualLevels.' }
    StructureResistanceMultiplier          = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.05; Max=5.0; Note='Lower makes structures take less damage. 1.0 is vanilla, 0.1 is nearly indestructible.' }
    DinoCharacterFoodDrainMultiplier        = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1; Max=10.0; Note='Lower means dinos (wild and tamed) get hungry more slowly.' }
    DinoCharacterStaminaDrainMultiplier     = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1; Max=10.0; Note='Lower means dinos tire out more slowly while sprinting or flying.' }
    PvEDinoDecayPeriodMultiplier            = @{ TargetFile='GameUserSettings.ini'; Section='[ServerSettings]'; Min=0.1; Max=10.0; Note='In PvE, lower makes dinos left by an absent tribe decay/die off sooner.' }
}

$script:AllowedActions = [ordered]@{
    StartServer      = 'Starts the ASA server if it is not already running.'
    SafeStop         = 'Safely saves the world and stops the ASA server. Disconnects all players.'
    Restart          = 'Warns connected players, then safely stops and restarts the ASA server.'
    UpdateAndRestart = 'Warns players, safely stops ASA, updates the official Steam server files (App 2430930), and restarts.'
    SafeBackup       = 'Warns players if online, safely stops ASA, creates a full save backup, and restarts if it had been running.'
}

# Item/resource class names the AI may reference in a custom crafting recipe
# override (ConfigOverrideItemCraftingCosts). Every entry was verified against
# ark.wiki.gg blueprint paths on 2026-08-22 -- never let the model reference a
# class string that isn't in this map. An unrecognized item class doesn't
# error in-game, it just silently no-ops, which is worse than a rejection.
$script:AsaItemClassAliases = [ordered]@{
    # Kibble tiers (ASA "Homestead" reworked kibble; tier = egg size)
    'basic kibble'          = 'PrimalItemConsumable_Kibble_Base_XSmall_C'
    'xsmall kibble'         = 'PrimalItemConsumable_Kibble_Base_XSmall_C'
    'simple kibble'         = 'PrimalItemConsumable_Kibble_Base_Small_C'
    'small kibble'          = 'PrimalItemConsumable_Kibble_Base_Small_C'
    'regular kibble'        = 'PrimalItemConsumable_Kibble_Base_Medium_C'
    'medium kibble'         = 'PrimalItemConsumable_Kibble_Base_Medium_C'
    'superior kibble'       = 'PrimalItemConsumable_Kibble_Base_Large_C'
    'large kibble'          = 'PrimalItemConsumable_Kibble_Base_Large_C'
    'exceptional kibble'    = 'PrimalItemConsumable_Kibble_Base_XLarge_C'
    'xlarge kibble'         = 'PrimalItemConsumable_Kibble_Base_XLarge_C'
    'extraordinary kibble'  = 'PrimalItemConsumable_Kibble_Base_Special_C'
    'special kibble'        = 'PrimalItemConsumable_Kibble_Base_Special_C'

    # Species-specific kibble (legacy per-species recipes, still craftable)
    'rex kibble'              = 'PrimalItemConsumable_Kibble_RexEgg_C'
    'raptor kibble'           = 'PrimalItemConsumable_Kibble_RaptorEgg_C'
    'argentavis kibble'       = 'PrimalItemConsumable_Kibble_ArgentEgg_C'
    'argent kibble'           = 'PrimalItemConsumable_Kibble_ArgentEgg_C'
    'quetzal kibble'          = 'PrimalItemConsumable_Kibble_QuetzEgg_C'
    'quetz kibble'            = 'PrimalItemConsumable_Kibble_QuetzEgg_C'
    'spino kibble'            = 'PrimalItemConsumable_Kibble_SpinoEgg_C'
    'spinosaurus kibble'      = 'PrimalItemConsumable_Kibble_SpinoEgg_C'
    'triceratops kibble'      = 'PrimalItemConsumable_Kibble_TrikeEgg_C'
    'trike kibble'            = 'PrimalItemConsumable_Kibble_TrikeEgg_C'
    'stegosaurus kibble'      = 'PrimalItemConsumable_Kibble_StegoEgg_C'
    'stego kibble'            = 'PrimalItemConsumable_Kibble_StegoEgg_C'
    'pteranodon kibble'       = 'PrimalItemConsumable_Kibble_PteroEgg_C'
    'ptero kibble'            = 'PrimalItemConsumable_Kibble_PteroEgg_C'
    'carnotaurus kibble'      = 'PrimalItemConsumable_Kibble_CarnoEgg_C'
    'carno kibble'            = 'PrimalItemConsumable_Kibble_CarnoEgg_C'
    'sarco kibble'            = 'PrimalItemConsumable_Kibble_SarcoEgg_C'
    'sarcosuchus kibble'      = 'PrimalItemConsumable_Kibble_SarcoEgg_C'
    'baryonyx kibble'         = 'PrimalItemConsumable_Kibble_BaryonyxEgg_C'
    'megalosaurus kibble'     = 'PrimalItemConsumable_Kibble_MegalosaurusEgg_C'
    'therizinosaurus kibble'  = 'PrimalItemConsumable_Kibble_TherizinoEgg_C'
    'therizino kibble'        = 'PrimalItemConsumable_Kibble_TherizinoEgg_C'
    'rock drake kibble'       = 'PrimalItemConsumable_Kibble_RockDrakeEgg_C'
    'rockdrake kibble'        = 'PrimalItemConsumable_Kibble_RockDrakeEgg_C'
    'kaprosuchus kibble'      = 'PrimalItemConsumable_Kibble_KaproEgg_C'
    'kapro kibble'            = 'PrimalItemConsumable_Kibble_KaproEgg_C'
    'compy kibble'            = 'PrimalItemConsumable_Kibble_Compy_C'
    'moth kibble'             = 'PrimalItemConsumable_Kibble_Moth_C'
    'vulture kibble'          = 'PrimalItemConsumable_Kibble_Vulture_C'
    'pelagornis kibble'       = 'PrimalItemConsumable_Kibble_Pela_C'
    'pela kibble'             = 'PrimalItemConsumable_Kibble_Pela_C'
    'mantis kibble'           = 'PrimalItemConsumable_Kibble_Mantis_C'
    'megalania kibble'        = 'PrimalItemConsumable_Kibble_Megalania_C'
    'dodo kibble'             = 'PrimalItemConsumable_Kibble_DodoEgg_C'
    'dilophosaur kibble'      = 'PrimalItemConsumable_Kibble_DiloEgg_C'
    'dilo kibble'             = 'PrimalItemConsumable_Kibble_DiloEgg_C'
    'parasaur kibble'         = 'PrimalItemConsumable_Kibble_ParaEgg_C'
    'iguanodon kibble'        = 'PrimalItemConsumable_Kibble_IguanodonEgg_C'
    'kentrosaurus kibble'     = 'PrimalItemConsumable_Kibble_KentroEgg_C'
    'kentro kibble'           = 'PrimalItemConsumable_Kibble_KentroEgg_C'
    'diplodocus kibble'       = 'PrimalItemConsumable_Kibble_DiploEgg_C'
    'diplo kibble'            = 'PrimalItemConsumable_Kibble_DiploEgg_C'
    'ankylosaurus kibble'     = 'PrimalItemConsumable_Kibble_AnkyloEgg_C'
    'ankylo kibble'           = 'PrimalItemConsumable_Kibble_AnkyloEgg_C'
    'gallimimus kibble'       = 'PrimalItemConsumable_Kibble_GalliEgg_C'
    'galli kibble'            = 'PrimalItemConsumable_Kibble_GalliEgg_C'
    'lystrosaurus kibble'     = 'PrimalItemConsumable_Kibble_LystroEgg_C'
    'lystro kibble'           = 'PrimalItemConsumable_Kibble_LystroEgg_C'
    'moschops kibble'         = 'PrimalItemConsumable_Kibble_MoschopsEgg_C'
    'oviraptor kibble'        = 'PrimalItemConsumable_Kibble_OviraptorEgg_C'
    'pachy kibble'            = 'PrimalItemConsumable_Kibble_PachyEgg_C'
    'pachycephalosaurus kibble' = 'PrimalItemConsumable_Kibble_PachyEgg_C'
    'pachyrhinosaurus kibble' = 'PrimalItemConsumable_Kibble_PachyRhinoEgg_C'
    'pegomastax kibble'       = 'PrimalItemConsumable_Kibble_PegomastaxEgg_C'
    'pulmonoscorpius kibble'  = 'PrimalItemConsumable_Kibble_ScorpionEgg_C'
    'scorpion kibble'         = 'PrimalItemConsumable_Kibble_ScorpionEgg_C'
    'araneo kibble'           = 'PrimalItemConsumable_Kibble_SpiderEgg_C'
    'spider kibble'           = 'PrimalItemConsumable_Kibble_SpiderEgg_C'
    'tapejara kibble'         = 'PrimalItemConsumable_Kibble_TapejaraEgg_C'
    'terror bird kibble'      = 'PrimalItemConsumable_Kibble_TerrorbirdEgg_C'
    'terrorbird kibble'       = 'PrimalItemConsumable_Kibble_TerrorbirdEgg_C'
    'troodon kibble'          = 'PrimalItemConsumable_Kibble_TroodonEgg_C'
    'carbonemys kibble'       = 'PrimalItemConsumable_Kibble_TurtleEgg_C'
    'turtle kibble'           = 'PrimalItemConsumable_Kibble_TurtleEgg_C'
    'titanoboa kibble'        = 'PrimalItemConsumable_Kibble_BoaEgg_C'
    'boa kibble'              = 'PrimalItemConsumable_Kibble_BoaEgg_C'
    'archaeopteryx kibble'    = 'PrimalItemConsumable_Kibble_ArchaEgg_C'
    'archa kibble'            = 'PrimalItemConsumable_Kibble_ArchaEgg_C'
    'allosaurus kibble'       = 'PrimalItemConsumable_Kibble_Allo_C'
    'allo kibble'             = 'PrimalItemConsumable_Kibble_Allo_C'
    'camelsaurus kibble'      = 'PrimalItemConsumable_Kibble_Camelsaurus_C'
    'dimetrodon kibble'       = 'PrimalItemConsumable_Kibble_DimetroEgg_C'
    'dimorphodon kibble'      = 'PrimalItemConsumable_Kibble_DimorphEgg_C'
    'ichthyornis kibble'      = 'PrimalItemConsumable_Kibble_IchthyornisEgg_C'
    'microraptor kibble'      = 'PrimalItemConsumable_Kibble_MicroraptorEgg_C'
    'brontosaurus kibble'     = 'PrimalItemConsumable_Kibble_SauroEgg_C'
    'sauropod kibble'         = 'PrimalItemConsumable_Kibble_SauroEgg_C'

    # Common resources / ingredients
    'thatch'             = 'PrimalItemResource_Thatch_C'
    'wood'               = 'PrimalItemResource_Wood_C'
    'stone'              = 'PrimalItemResource_Stone_C'
    'flint'              = 'PrimalItemResource_Flint_C'
    'metal'              = 'PrimalItemResource_Metal_C'
    'metal ingot'        = 'PrimalItemResource_MetalIngot_C'
    'crystal'            = 'PrimalItemResource_Crystal_C'
    'obsidian'           = 'PrimalItemResource_Obsidian_C'
    'clay'               = 'PrimalItemResource_Clay_C'
    'silica pearls'      = 'PrimalItemResource_Silicon_C'
    'black pearls'       = 'PrimalItemResource_BlackPearl_C'
    'cementing paste'    = 'PrimalItemResource_ChitinPaste_C'
    'achatina paste'     = 'PrimalItemResource_ChitinPaste_C'
    'chitin'             = 'PrimalItemResource_Chitin_C'
    'keratin'            = 'PrimalItemResource_Keratin_C'
    'hide'               = 'PrimalItemResource_Hide_C'
    'pelt'               = 'PrimalItemResource_Pelt_C'
    'fiber'              = 'PrimalItemResource_Fibers_C'
    'gasoline'           = 'PrimalItemResource_Gasoline_C'
    'gunpowder'          = 'PrimalItemResource_Gunpowder_C'
    'sparkpowder'        = 'PrimalItemResource_Sparkpowder_C'
    'electronics'        = 'PrimalItemResource_Electronics_C'
    'polymer'            = 'PrimalItemResource_Polymer_C'
    'organic polymer'    = 'PrimalItemResource_Polymer_Organic_C'
    'element'            = 'PrimalItemResource_Element_C'
    'element dust'       = 'PrimalItemResource_ElementDust_C'
    'element shard'      = 'PrimalItemResource_ElementShard_C'
    'element ore'        = 'PrimalItemResource_ElementOre_C'
    'rare flower'        = 'PrimalItemResource_RareFlower_C'
    'rare mushroom'      = 'PrimalItemResource_RareMushroom_C'
    'ambergris'          = 'PrimalItemResource_Ambergris_C'
    'angler gel'         = 'PrimalItemResource_AnglerGel_C'
    'silk'               = 'PrimalItemResource_Silk_C'
    'propellant'         = 'PrimalItemResource_Propellant_C'
    'preserving salt'    = 'PrimalItemResource_PreservingSalt_C'
    'charcoal'           = 'PrimalItemResource_Charcoal_C'
    'scrap metal'        = 'PrimalItemResource_ScrapMetal_C'
    'scrap metal ingot'  = 'PrimalItemResource_ScrapMetalIngot_C'
    'sap'                = 'PrimalItemResource_Sap_C'
    'oil'                = 'PrimalItemResource_Oil_C'
    'sand'               = 'PrimalItemResource_Sand_C'
    'sulfur'             = 'PrimalItemResource_Sulfur_C'
    'giant bee honey'    = 'PrimalItemConsumable_Honey_C'
    'honey'              = 'PrimalItemConsumable_Honey_C'

    # Common consumables / foods
    'cooked meat'         = 'PrimalItemConsumable_CookedMeat_C'
    'raw meat'            = 'PrimalItemConsumable_RawMeat_C'
    'cooked meat jerky'   = 'PrimalItemConsumable_CookedMeat_Jerky_C'
    'cooked prime meat'   = 'PrimalItemConsumable_CookedPrimeMeat_C'
    'raw prime meat'      = 'PrimalItemConsumable_RawPrimeMeat_C'
    'prime meat jerky'    = 'PrimalItemConsumable_CookedPrimeMeat_Jerky_C'
    'raw mutton'          = 'PrimalItemConsumable_RawMutton_C'
    'spoiled meat'        = 'PrimalItemConsumable_SpoiledMeat_C'
    'cooked fish meat'    = 'PrimalItemConsumable_CookedMeat_Fish_C'
    'raw fish meat'       = 'PrimalItemConsumable_RawMeat_Fish_C'
    'mejoberry'           = 'PrimalItemConsumable_Berry_Mejoberry_C'
    'narcoberry'          = 'PrimalItemConsumable_Berry_Narcoberry_C'
    'stimberry'           = 'PrimalItemConsumable_Berry_Stimberry_C'
    'amarberry'           = 'PrimalItemConsumable_Berry_Amarberry_C'
    'azulberry'           = 'PrimalItemConsumable_Berry_Azulberry_C'
    'tintoberry'          = 'PrimalItemConsumable_Berry_Tintoberry_C'
    'longrass'            = 'PrimalItemConsumable_Veggie_Longrass_C'
    'rockarrot'           = 'PrimalItemConsumable_Veggie_Rockarrot_C'
    'savoroot'            = 'PrimalItemConsumable_Veggie_Savoroot_C'
    'citronal'            = 'PrimalItemConsumable_Veggie_Citronal_C'
    'narcotic'            = 'PrimalItemConsumable_Narcotic_C'
    'stimulant'           = 'PrimalItemConsumable_Stimulant_C'
    'waterskin'           = 'PrimalItemConsumable_WaterskinCraftable_C'
    'water jar'           = 'PrimalItemConsumable_WaterJarCraftable_C'
    'lazarus chowder'     = 'PrimalItemConsumable_Soup_LazarusChowder_C'
    'focal chili'         = 'PrimalItemConsumable_Soup_FocalChili_C'

    # Common craftable tools/weapons (recipe targets)
    'stone hatchet'  = 'PrimalItem_WeaponStoneHatchet_C'
    'metal hatchet'  = 'PrimalItem_WeaponMetalHatchet_C'
    'stone pick'     = 'PrimalItem_WeaponStonePick_C'
    'metal pick'     = 'PrimalItem_WeaponMetalPick_C'
    'torch'          = 'PrimalItem_WeaponTorch_C'
    'sickle'         = 'PrimalItem_WeaponSickle_C'
    'fishing rod'    = 'PrimalItem_WeaponFishingRod_C'
    'gps'            = 'PrimalItem_WeaponGPS_C'
    'compass'        = 'PrimalItem_WeaponCompass_C'
    'binoculars'     = 'PrimalItem_WeaponElectronicBinoculars_C'
}

function Resolve-AsaItemClass {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $trimmed = $Name.Trim()
    if (-not $trimmed) { return $null }

    # Only accept a raw class string ending in _C if it is one we already
    # recognize -- never trust an unrecognized class string typed or guessed
    # by the model, since it would write a silent no-op recipe in-game.
    if ($trimmed -match '^[A-Za-z0-9_]+_C$') {
        if (@($script:AsaItemClassAliases.Values) -icontains $trimmed) { return $trimmed }
        return $null
    }

    $normalized = ($trimmed.ToLowerInvariant() -replace '\s+', ' ')
    if ($script:AsaItemClassAliases.Contains($normalized)) {
        return $script:AsaItemClassAliases[$normalized]
    }
    return $null
}

function ConvertTo-AsaRecipeIniLine {
    param([Parameter(Mandatory)]$Recipe)

    $resourceParts = foreach ($resource in @($Recipe.Resources)) {
        $amountText = ([decimal]$resource.Amount).ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
        '(ResourceItemTypeString="' + $resource.Class + '",BaseResourceRequirement=' + $amountText + ',bCraftingRequireExactResourceType=False)'
    }
    return 'ConfigOverrideItemCraftingCosts=(ItemClassString="' + $Recipe.ItemClass + '",BaseCraftingResourceRequirements=(' + ($resourceParts -join ',') + '))'
}

function ConvertTo-AsaRecipeSummaryText {
    param([Parameter(Mandatory)][string]$Line)

    $resourceMatches = [regex]::Matches($Line, 'ResourceItemTypeString="(?<r>[^"]+)"[^)]*BaseResourceRequirement=(?<a>[0-9.]+)')
    if ($resourceMatches.Count -eq 0) { return $Line }
    return (@($resourceMatches | ForEach-Object { $_.Groups['r'].Value + ' x' + $_.Groups['a'].Value }) -join ', ')
}

function Format-AsaRelocationPreviewText {
    <#
    Renders one validated relocation as a single, unambiguous MOVE block --
    never as two unrelated-looking changes -- for CLI/Panel preview. Pure
    formatting; never writes anything, matches whatever the validated
    relocation object (already computed by Get-AsaSettingRelocationPlan)
    actually says it will do.
    #>
    param([Parameter(Mandatory)]$Relocation)

    $valueText = ($Relocation.SourceValues -join ', ')
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('MOVE')
    [void]$lines.Add("$($Relocation.Setting)=$valueText")
    [void]$lines.Add('')
    [void]$lines.Add('FROM:')
    [void]$lines.Add("$($Relocation.FromTarget) $($Relocation.FromSection)")
    [void]$lines.Add('')
    [void]$lines.Add('TO:')
    [void]$lines.Add("$($Relocation.ToTarget) $($Relocation.ToSection)")

    if ($Relocation.DestinationHadExisting) {
        [void]$lines.Add('')
        [void]$lines.Add('Destination conflict:')
        if ($Relocation.WriteDestination) {
            [void]$lines.Add("The destination already had a value for $($Relocation.Setting); it will be overwritten with the source value ($valueText).")
        }
        else {
            [void]$lines.Add("The destination already had this value; the duplicate source entry will simply be removed. Nothing at the destination changes.")
        }
    }

    [void]$lines.Add('')
    [void]$lines.Add('Reason:')
    [void]$lines.Add([string]$Relocation.Reason)
    [void]$lines.Add('')
    [void]$lines.Add("Value preserved: $valueText")
    return ($lines -join "`r`n")
}

function Get-AsaAiAllowedActionText {
    $lines = foreach ($key in $script:AllowedActions.Keys) {
        "- ${key}: $($script:AllowedActions[$key])"
    }
    return ($lines -join "`n")
}

function Get-AsaAiRunningServerProcess {
    Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Invoke-AsaAiServerAction {
    param([Parameter(Mandatory)][string]$Action)

    $root = $PSScriptRoot
    switch ($Action) {
        'StartServer' {
            if (Get-AsaAiRunningServerProcess) {
                return [pscustomobject]@{ Success = $true; Message = 'ASA is already running.' }
            }
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f (Join-Path $root 'StartServer.bat')) -WorkingDirectory $root -WindowStyle Hidden
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Seconds 1
                if (Get-AsaAiRunningServerProcess) {
                    return [pscustomobject]@{ Success = $true; Message = 'ASA start requested and the process is now running. Full world load still takes a few minutes.' }
                }
            }
            return [pscustomobject]@{ Success = $false; Message = 'ASA start was requested but no process appeared within 20 seconds.' }
        }
        'SafeStop' {
            if (-not (Get-AsaAiRunningServerProcess)) {
                return [pscustomobject]@{ Success = $true; Message = 'ASA is already stopped.' }
            }
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'StopServer.ps1') -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                return [pscustomobject]@{ Success = $false; Message = 'Safe shutdown did not complete. The server was not force-killed.' }
            }
            return [pscustomobject]@{ Success = $true; Message = 'ASA was saved and safely stopped.' }
        }
        'Restart' {
            Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"{0}"' -f (Join-Path $root 'RestartServer.bat')) -WorkingDirectory $root -WindowStyle Hidden
            return [pscustomobject]@{ Success = $true; Message = 'Restart requested: players are being warned (60/30/10s), then ASA will safely stop and start again.' }
        }
        'UpdateAndRestart' {
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'Update-And-Restart.ps1'), '-NoPause' -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                return [pscustomobject]@{ Success = $false; Message = "Update failed (exit code $($process.ExitCode)). Run Update-And-Restart.ps1 manually to see full SteamCMD output." }
            }
            return [pscustomobject]@{ Success = $true; Message = 'ASA was updated/validated against Steam App 2430930 and restarted if it had been running.' }
        }
        'SafeBackup' {
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'SafeBackup-And-Restart.ps1'), '-NoPause' -WorkingDirectory $root -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                return [pscustomobject]@{ Success = $false; Message = "Backup failed (exit code $($process.ExitCode)). No confirmed new backup was made." }
            }
            return [pscustomobject]@{ Success = $true; Message = 'A full save backup was created; ASA was restarted afterward if it had been running.' }
        }
        default {
            return [pscustomobject]@{ Success = $false; Message = "Unknown or blocked action: $Action" }
        }
    }
}

function Get-AsaAiAllowedSettingText {
    $paths = Get-AsaAiFixedConfigPaths
    $gameUserLines = if (Test-Path -LiteralPath $paths.GameUserSettings) { [IO.File]::ReadAllLines($paths.GameUserSettings) } else { @() }
    $gameIniLines = if (Test-Path -LiteralPath $paths.GameIni) { [IO.File]::ReadAllLines($paths.GameIni) } else { @() }

    $lines = foreach ($key in $script:AllowedSettings.Keys) {
        $meta = $script:AllowedSettings[$key]
        $sourceLines = if ($meta.TargetFile -ceq 'GameUserSettings.ini') { $gameUserLines } else { $gameIniLines }
        $current = Get-AsaIniValueFromLines -Lines $sourceLines -Section $meta.Section -Key $key
        $currentText = if ($null -ne $current -and [string]$current -ne '') { [string]$current } else { 'not set (game uses its own default)' }

        if ([string]$meta.Type -ceq 'Boolean') {
            "- ${key}: CURRENT VALUE = $currentText. True/False. $($meta.Note)"
        }
        else {
            "- ${key}: CURRENT VALUE = $currentText. Allowed range $($meta.Min) to $($meta.Max). $($meta.Note)"
        }
    }
    return ($lines -join "`n")
}

function ConvertTo-AsaValidatedProposal {
    param([Parameter(Mandatory)]$RawProposal)

    $validated = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[string]

    foreach ($change in @($RawProposal.changes)) {
        $key = [string]$change.key
        if (-not $script:AllowedSettings.Contains($key)) {
            $rejected.Add("Unknown or blocked setting: $key")
            continue
        }

        $meta = $script:AllowedSettings[$key]
        $rawValue = [string]$change.value

        Remove-Variable -Name value, numericValue -ErrorAction SilentlyContinue

        if ([string]$meta.Type -ceq 'Boolean') {
            if ($rawValue -inotin @('True', 'False')) {
                $rejected.Add("Invalid boolean value for ${key}: $rawValue (must be True or False)")
                continue
            }
            $value = if ($rawValue -ieq 'True') { 'True' } else { 'False' }
        }
        else {
            [decimal]$numericValue = 0
            $parsed = [decimal]::TryParse(
                $rawValue,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$numericValue
            )

            if (-not $parsed) {
                $rejected.Add("Invalid numeric value for ${key}: $rawValue")
                continue
            }

            if ($numericValue -lt [decimal]$meta.Min -or $numericValue -gt [decimal]$meta.Max) {
                $rejected.Add("Out-of-range value for ${key}: $numericValue (allowed $($meta.Min)-$($meta.Max))")
                continue
            }
            $value = $numericValue
        }

        $validated.Add([pscustomobject]@{
            Key        = $key
            Value      = $value
            TargetFile = [string]$meta.TargetFile
            Section    = [string]$meta.Section
            Reason     = [string]$change.reason
        })
    }

    $validatedActions = New-Object System.Collections.Generic.List[object]
    $seenActions = @{}
    foreach ($action in @($RawProposal.actions)) {
        $name = [string]$action.name
        if (-not $script:AllowedActions.Contains($name)) {
            $rejected.Add("Unknown or blocked action: $name")
            continue
        }
        if ($seenActions.ContainsKey($name)) {
            $rejected.Add("Duplicate action: $name")
            continue
        }
        $seenActions[$name] = $true
        $validatedActions.Add([pscustomobject]@{
            Name   = $name
            Reason = [string]$action.reason
        })
    }

    $validatedRecipes = New-Object System.Collections.Generic.List[object]
    foreach ($recipe in @($RawProposal.recipes)) {
        $itemName = [string]$recipe.item
        $itemClass = Resolve-AsaItemClass -Name $itemName
        if (-not $itemClass) {
            $rejected.Add("Unknown or unrecognized item for custom recipe: $itemName")
            continue
        }

        $resourceEntries = New-Object System.Collections.Generic.List[object]
        $recipeRejected = $false
        foreach ($resource in @($recipe.resources)) {
            $resourceName = [string]$resource.resource
            $resourceClass = Resolve-AsaItemClass -Name $resourceName
            if (-not $resourceClass) {
                $rejected.Add("Unknown or unrecognized resource '$resourceName' in recipe for ${itemName}")
                $recipeRejected = $true
                continue
            }

            Remove-Variable -Name amount -ErrorAction SilentlyContinue
            [decimal]$amount = 0
            $amountText = [string]$resource.amount
            $amountParsed = [decimal]::TryParse(
                $amountText,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$amount
            )
            if (-not $amountParsed -or $amount -lt 0.01 -or $amount -gt 1000000) {
                $rejected.Add("Invalid amount '$amountText' for resource '$resourceName' in recipe for ${itemName}")
                $recipeRejected = $true
                continue
            }

            $resourceEntries.Add([pscustomobject]@{ Class = $resourceClass; Amount = $amount })
        }

        if ($recipeRejected) { continue }
        if ($resourceEntries.Count -eq 0) {
            $rejected.Add("Recipe for $itemName has no valid resources.")
            continue
        }

        $validatedRecipes.Add([pscustomobject]@{
            ItemName  = $itemName
            ItemClass = $itemClass
            Resources = $resourceEntries.ToArray()
            Reason    = [string]$recipe.reason
        })
    }

    $validatedRelocations = New-Object System.Collections.Generic.List[object]
    $relocationCandidates = @($RawProposal.relocations)
    if ($relocationCandidates.Count -gt 0) {
        $paths = Get-AsaAiFixedConfigPaths
        $guLines = if (Test-Path -LiteralPath $paths.GameUserSettings) { [IO.File]::ReadAllLines($paths.GameUserSettings) } else { @() }
        $giLines = if (Test-Path -LiteralPath $paths.GameIni) { [IO.File]::ReadAllLines($paths.GameIni) } else { @() }

        foreach ($relocation in $relocationCandidates) {
            $settingName = [string]$relocation.setting
            if ([string]::IsNullOrWhiteSpace($settingName)) {
                $rejected.Add('A proposed relocation has no setting name.')
                continue
            }
            $plan = Get-AsaSettingRelocationPlan -SettingName $settingName -GameUserSettingsLines $guLines -GameIniLines $giLines
            if (-not $plan.Success) {
                $rejected.Add("Relocation refused for ${settingName}: $($plan.Error)")
                continue
            }
            $validatedRelocations.Add([pscustomobject]@{
                Setting          = $plan.Setting
                FromTarget       = $plan.FromTarget
                FromSection      = $plan.FromSection
                ToTarget         = $plan.ToTarget
                ToSection        = $plan.ToSection
                Repeatable       = $plan.Repeatable
                SourceLines      = $plan.SourceLines
                SourceValues     = $plan.SourceValues
                WriteDestination = $plan.WriteDestination
                DestinationLines = $plan.DestinationLines
                DestinationHadExisting = $plan.DestinationHadExisting
                Reason           = [string]$relocation.reason
                PlanReason       = $plan.Reason
            })
        }
    }

    return [pscustomobject]@{
        Summary     = [string]$RawProposal.summary
        Changes     = $validated.ToArray()
        Actions     = $validatedActions.ToArray()
        Recipes     = $validatedRecipes.ToArray()
        Relocations = $validatedRelocations.ToArray()
        Rejected    = $rejected.ToArray()
        ReadOnly    = $true
    }
}

function Test-AsaAiApplyProposal {
    param([Parameter(Mandatory)]$Proposal)

    $proposalChanges = @($Proposal.Changes)
    $proposalRecipes = @($Proposal.Recipes)
    $proposalRelocations = @($Proposal.Relocations)
    if ($proposalChanges.Count -eq 0 -and $proposalRecipes.Count -eq 0 -and $proposalRelocations.Count -eq 0) {
        return [pscustomobject]@{
            Success     = $false
            Changes     = @()
            Recipes     = @()
            Relocations = @()
            Error       = 'Proposal must contain at least one setting change, custom recipe, or relocation.'
        }
    }

    $seenKeys = @{}
    $changes = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($change in $proposalChanges) {
        $key = [string]$change.Key
        if ([string]::IsNullOrWhiteSpace($key)) {
            $errors.Add('A proposed setting has no key.')
            continue
        }

        if ($seenKeys.ContainsKey($key)) {
            $errors.Add("Duplicate key: ${key}")
            continue
        }
        $seenKeys[$key] = $true

        if (-not $script:AllowedSettings.Contains($key)) {
            $errors.Add("Unknown or blocked setting: ${key}")
            continue
        }

        $meta = $script:AllowedSettings[$key]
        $targetFile = [string]$meta.TargetFile
        $section = [string]$meta.Section
        $metadataAllowed = (
            ($targetFile -ceq 'GameUserSettings.ini' -and $section -ceq '[ServerSettings]') -or
            ($targetFile -ceq 'Game.ini' -and $section -ceq '[/Script/ShooterGame.ShooterGameMode]') -or
            ($targetFile -ceq 'GameUserSettings.ini' -and $section -ceq '[CustomLevelDistrib]')
        )
        if (-not $metadataAllowed) {
            $errors.Add("Blocked metadata for setting: ${key}")
            continue
        }

        $rawValue = [string]$change.Value
        Remove-Variable -Name value, numericValue -ErrorAction SilentlyContinue

        if ([string]$meta.Type -ceq 'Boolean') {
            if ($rawValue -inotin @('True', 'False')) {
                $errors.Add("Invalid boolean value for ${key}: $rawValue (must be True or False)")
                continue
            }
            $value = if ($rawValue -ieq 'True') { 'True' } else { 'False' }
        }
        else {
            [decimal]$numericValue = 0
            $parsed = [decimal]::TryParse(
                $rawValue,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$numericValue
            )

            if (-not $parsed) {
                $errors.Add("Invalid numeric value for ${key}: $rawValue")
                continue
            }

            if ($numericValue -lt [decimal]$meta.Min -or $numericValue -gt [decimal]$meta.Max) {
                $errors.Add("Out-of-range value for ${key}: $numericValue (allowed $($meta.Min)-$($meta.Max))")
                continue
            }
            $value = $numericValue
        }

        $changes.Add([pscustomobject]@{
            Key        = $key
            Value      = $value
            TargetFile = $targetFile
            Section    = $section
            Reason     = [string]$change.Reason
        })
    }

    $recipes = New-Object System.Collections.Generic.List[object]
    foreach ($recipe in $proposalRecipes) {
        $itemClass = [string]$recipe.ItemClass
        if (-not (@($script:AsaItemClassAliases.Values) -icontains $itemClass)) {
            $errors.Add("Blocked item class for custom recipe: $itemClass")
            continue
        }

        $resourceEntries = New-Object System.Collections.Generic.List[object]
        foreach ($resource in @($recipe.Resources)) {
            $resourceClass = [string]$resource.Class
            if (-not (@($script:AsaItemClassAliases.Values) -icontains $resourceClass)) {
                $errors.Add("Blocked resource class in recipe for ${itemClass}: $resourceClass")
                continue
            }
            [decimal]$resourceAmount = [decimal]$resource.Amount
            if ($resourceAmount -lt 0.01 -or $resourceAmount -gt 1000000) {
                $errors.Add("Out-of-range resource amount in recipe for ${itemClass}: $resourceAmount")
                continue
            }
            $resourceEntries.Add([pscustomobject]@{ Class = $resourceClass; Amount = $resourceAmount })
        }

        if ($resourceEntries.Count -eq 0) {
            $errors.Add("Recipe for $itemClass has no valid resources after re-validation.")
            continue
        }

        $recipes.Add([pscustomobject]@{
            ItemName  = [string]$recipe.ItemName
            ItemClass = $itemClass
            Resources = $resourceEntries.ToArray()
            Reason    = [string]$recipe.Reason
        })
    }

    # Relocations are always re-derived from scratch against the CURRENT live
    # config -- the destination (and even whether the source still exists in
    # the wrong place) is never trusted from an earlier layer, only the
    # setting name (and an optional caller-supplied conflict resolution).
    $relocations = New-Object System.Collections.Generic.List[object]
    if ($proposalRelocations.Count -gt 0) {
        $paths = Get-AsaAiFixedConfigPaths
        $currentGuLines = if (Test-Path -LiteralPath $paths.GameUserSettings) { [IO.File]::ReadAllLines($paths.GameUserSettings) } else { @() }
        $currentGiLines = if (Test-Path -LiteralPath $paths.GameIni) { [IO.File]::ReadAllLines($paths.GameIni) } else { @() }

        foreach ($relocation in $proposalRelocations) {
            $settingName = [string]$relocation.Setting
            if ([string]::IsNullOrWhiteSpace($settingName)) {
                $errors.Add('A proposed relocation has no setting name.')
                continue
            }

            $planParams = @{
                SettingName            = $settingName
                GameUserSettingsLines  = $currentGuLines
                GameIniLines           = $currentGiLines
            }
            $resolution = [string]$relocation.Resolution
            if ($resolution -in @('use_source', 'keep_destination')) { $planParams.Resolution = $resolution }

            $plan = Get-AsaSettingRelocationPlan @planParams
            if (-not $plan.Success) {
                $errors.Add("Relocation refused for ${settingName}: $($plan.Error)")
                continue
            }

            $relocations.Add([pscustomobject]@{
                Setting          = $plan.Setting
                FromTarget       = $plan.FromTarget
                FromSection      = $plan.FromSection
                ToTarget         = $plan.ToTarget
                ToSection        = $plan.ToSection
                Repeatable       = $plan.Repeatable
                SourceLines      = $plan.SourceLines
                SourceValues     = $plan.SourceValues
                WriteDestination = $plan.WriteDestination
                DestinationLines = $plan.DestinationLines
                DestinationHadExisting = $plan.DestinationHadExisting
                Reason           = [string]$relocation.Reason
            })
        }
    }

    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            Success     = $false
            Changes     = @()
            Recipes     = @()
            Relocations = @()
            Error       = ($errors.ToArray() -join "`n")
        }
    }

    return [pscustomobject]@{
        Success     = $true
        Changes     = $changes.ToArray()
        Recipes     = $recipes.ToArray()
        Relocations = $relocations.ToArray()
        Error       = ''
    }
}

function Set-AsaIniValueInMemory {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $copy = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        [void]$copy.Add([string]$line)
    }

    $sectionIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -ieq $Section) {
            $sectionIndexes.Add($i)
        }
    }

    if ($sectionIndexes.Count -eq 0) {
        throw "Required INI section not found: $Section"
    }
    if ($sectionIndexes.Count -gt 1) {
        throw "Duplicate INI section is ambiguous: $Section"
    }

    $sectionIndex = $sectionIndexes[0]
    $nextSectionIndex = $copy.Count
    for ($i = $sectionIndex + 1; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -match '^\[[^\]]+\]$') {
            $nextSectionIndex = $i
            break
        }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $keyIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = $sectionIndex + 1; $i -lt $nextSectionIndex; $i++) {
        if ($copy[$i] -match $keyPattern) {
            $keyIndexes.Add($i)
        }
    }

    if ($keyIndexes.Count -gt 1) {
        throw "Duplicate INI key is ambiguous in ${Section}: $Key"
    }

    $replacement = $Key + '=' + $Value
    if ($keyIndexes.Count -eq 1) {
        $copy[$keyIndexes[0]] = $replacement
    }
    else {
        $copy.Insert($nextSectionIndex, $replacement)
    }

    return [string[]]$copy.ToArray()
}

function Get-AsaIniValueFromLines {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $sectionIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -ieq $Section) { $sectionIndex = $i; break }
    }
    if ($sectionIndex -lt 0) { return $null }

    $nextSectionIndex = $Lines.Count
    for ($i = $sectionIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -match '^\[[^\]]+\]$') { $nextSectionIndex = $i; break }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($i = $sectionIndex + 1; $i -lt $nextSectionIndex; $i++) {
        if ($Lines[$i] -match $keyPattern) {
            return $Lines[$i].Substring($Lines[$i].IndexOf('=') + 1)
        }
    }
    return $null
}

function Get-AsaIniSectionRepeatedLines {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $sectionIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -ieq $Section) { $sectionIndex = $i; break }
    }
    if ($sectionIndex -lt 0) { return @() }

    $nextSectionIndex = $Lines.Count
    for ($i = $sectionIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -match '^\[[^\]]+\]$') { $nextSectionIndex = $i; break }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $result = New-Object System.Collections.Generic.List[string]
    for ($i = $sectionIndex + 1; $i -lt $nextSectionIndex; $i++) {
        if ($Lines[$i] -match $keyPattern) { $result.Add($Lines[$i]) }
    }
    return [string[]]$result.ToArray()
}

function Set-AsaIniSectionRepeatedLinesInMemory {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$NewLines
    )

    $copy = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { [void]$copy.Add([string]$line) }

    $sectionIndex = -1
    for ($i = 0; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -ieq $Section) { $sectionIndex = $i; break }
    }
    if ($sectionIndex -lt 0) {
        if ($copy.Count -gt 0 -and $copy[$copy.Count - 1] -ne '') { [void]$copy.Add('') }
        [void]$copy.Add($Section)
        $sectionIndex = $copy.Count - 1
    }

    $nextSectionIndex = $copy.Count
    for ($i = $sectionIndex + 1; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -match '^\[[^\]]+\]$') { $nextSectionIndex = $i; break }
    }

    for ($i = $nextSectionIndex - 1; $i -gt $sectionIndex; $i--) {
        if ($copy[$i] -match ('^\s*' + [regex]::Escape($Key) + '=')) { $copy.RemoveAt($i) }
    }

    $insertAt = $copy.Count
    for ($i = $sectionIndex + 1; $i -lt $copy.Count; $i++) {
        if ($copy[$i].Trim() -match '^\[[^\]]+\]$') { $insertAt = $i; break }
    }
    foreach ($line in @($NewLines)) {
        if ($line) { $copy.Insert($insertAt, $line); $insertAt++ }
    }

    return [string[]]$copy.ToArray()
}

function Add-AsaChangelogEntry {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$NewValue,
        [string]$OldValue = '(not previously set)',
        [Parameter(Mandatory)][string]$TargetFile,
        [string]$Reason = '',
        [string]$BackupPath = ''
    )

    $changelogPath = (Get-AsaAiFixedConfigPaths).ChangelogPath
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "- **$timestamp** &mdash; ``$Key`` in $TargetFile`: ``$OldValue`` -> ``$NewValue``."
    if ($Reason) { $line += " Reason: $Reason" }
    if ($BackupPath) { $line += " Backup: ``$BackupPath``" }
    Add-Content -LiteralPath $changelogPath -Value $line -Encoding utf8
}

function Get-AsaAiFixedConfigPaths {
    # Test-only redirection hook: when a test sets this script-scope variable
    # to a pscustomobject with the same four properties, every path-consuming
    # function in this file (backup, apply, rollback, changelog) transparently
    # targets that isolated fixture instead of the real, live server config.
    # Production code paths never set this, so normal behavior is unchanged.
    if ($script:AsaAiTestConfigPathOverride) { return $script:AsaAiTestConfigPathOverride }

    $configRoot = Join-Path $PSScriptRoot 'server\ShooterGame\Saved\Config\WindowsServer'
    return [pscustomobject]@{
        GameUserSettings = Join-Path $configRoot 'GameUserSettings.ini'
        GameIni          = Join-Path $configRoot 'Game.ini'
        BackupRoot       = Join-Path $PSScriptRoot 'backups\AI-Config'
        ChangelogPath    = Join-Path $PSScriptRoot 'SETTINGS-CHANGELOG.md'
    }
}

function New-AsaAiPreparedApply {
    param([Parameter(Mandatory)]$Proposal)

    $validated = Test-AsaAiApplyProposal -Proposal $Proposal
    if (-not $validated.Success) {
        return [pscustomobject]@{
            Success = $false
            Error   = $validated.Error
            Changes = @()
        }
    }

    $paths = Get-AsaAiFixedConfigPaths
    if (-not [IO.File]::Exists($paths.GameUserSettings) -or -not [IO.File]::Exists($paths.GameIni)) {
        return [pscustomobject]@{
            Success = $false
            Error   = 'Both GameUserSettings.ini and Game.ini must exist before applying AI settings.'
            Changes = @()
        }
    }

    try {
        [string[]]$gameUserLines = [IO.File]::ReadAllLines($paths.GameUserSettings)
        [string[]]$gameIniLines = [IO.File]::ReadAllLines($paths.GameIni)
        $writeGameUserSettings = $false
        $writeGameIni = $false
        $changesWithOldValues = New-Object System.Collections.Generic.List[object]

        foreach ($change in $validated.Changes) {
            $valueText = if ([string]$change.Value -in @('True', 'False')) { [string]$change.Value } else { ([decimal]$change.Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
            if ($change.TargetFile -ceq 'GameUserSettings.ini') {
                $oldValue = Get-AsaIniValueFromLines -Lines $gameUserLines -Section $change.Section -Key $change.Key
                $gameUserLines = Set-AsaIniValueInMemory -Lines $gameUserLines -Section $change.Section -Key $change.Key -Value $valueText
                $writeGameUserSettings = $true
            }
            elseif ($change.TargetFile -ceq 'Game.ini') {
                $oldValue = Get-AsaIniValueFromLines -Lines $gameIniLines -Section $change.Section -Key $change.Key
                $gameIniLines = Set-AsaIniValueInMemory -Lines $gameIniLines -Section $change.Section -Key $change.Key -Value $valueText
                $writeGameIni = $true
            }
            else {
                throw "Blocked target file for setting: $($change.Key)"
            }
            $changesWithOldValues.Add([pscustomobject]@{
                Key        = $change.Key
                Value      = $change.Value
                OldValue   = if ($null -ne $oldValue) { $oldValue } else { '(not previously set)' }
                TargetFile = $change.TargetFile
                Reason     = $change.Reason
            })
        }

        $recipesApplied = New-Object System.Collections.Generic.List[object]
        $recipeSection = '[/Script/ShooterGame.ShooterGameMode]'
        $recipeKey = 'ConfigOverrideItemCraftingCosts'
        if (@($validated.Recipes).Count -gt 0) {
            $existingRecipeLines = New-Object System.Collections.Generic.List[string]
            [void]$existingRecipeLines.AddRange([string[]](Get-AsaIniSectionRepeatedLines -Lines $gameIniLines -Section $recipeSection -Key $recipeKey))

            foreach ($recipe in $validated.Recipes) {
                $newLine = ConvertTo-AsaRecipeIniLine -Recipe $recipe
                $matchPattern = 'ItemClassString="' + [regex]::Escape($recipe.ItemClass) + '"'
                $replaceIndex = -1
                for ($i = 0; $i -lt $existingRecipeLines.Count; $i++) {
                    if ($existingRecipeLines[$i] -match $matchPattern) { $replaceIndex = $i; break }
                }
                $oldSummary = if ($replaceIndex -ge 0) { ConvertTo-AsaRecipeSummaryText -Line $existingRecipeLines[$replaceIndex] } else { 'vanilla (no override yet)' }
                if ($replaceIndex -ge 0) { $existingRecipeLines[$replaceIndex] = $newLine } else { [void]$existingRecipeLines.Add($newLine) }

                $recipesApplied.Add([pscustomobject]@{
                    ItemName   = $recipe.ItemName
                    ItemClass  = $recipe.ItemClass
                    OldSummary = $oldSummary
                    NewSummary = ConvertTo-AsaRecipeSummaryText -Line $newLine
                    Reason     = $recipe.Reason
                })
            }

            $gameIniLines = Set-AsaIniSectionRepeatedLinesInMemory -Lines $gameIniLines -Section $recipeSection -Key $recipeKey -NewLines ([string[]]$existingRecipeLines.ToArray())
            $writeGameIni = $true
        }

        $relocationsApplied = New-Object System.Collections.Generic.List[object]
        foreach ($relocation in $validated.Relocations) {
            # Remove the source occurrence(s) -- unconditional whenever a plan
            # succeeded, regardless of whether the destination is written.
            if ($relocation.FromTarget -ceq 'GameUserSettings.ini') {
                $gameUserLines = Set-AsaIniSectionRepeatedLinesInMemory -Lines $gameUserLines -Section $relocation.FromSection -Key $relocation.Setting -NewLines @()
                $writeGameUserSettings = $true
            }
            elseif ($relocation.FromTarget -ceq 'Game.ini') {
                $gameIniLines = Set-AsaIniSectionRepeatedLinesInMemory -Lines $gameIniLines -Section $relocation.FromSection -Key $relocation.Setting -NewLines @()
                $writeGameIni = $true
            }
            else {
                throw "Blocked source file for relocation: $($relocation.Setting)"
            }

            if ($relocation.WriteDestination) {
                if ($relocation.ToTarget -ceq 'GameUserSettings.ini') {
                    $gameUserLines = Set-AsaIniSectionRepeatedLinesInMemory -Lines $gameUserLines -Section $relocation.ToSection -Key $relocation.Setting -NewLines ([string[]]$relocation.DestinationLines)
                    $writeGameUserSettings = $true
                }
                elseif ($relocation.ToTarget -ceq 'Game.ini') {
                    $gameIniLines = Set-AsaIniSectionRepeatedLinesInMemory -Lines $gameIniLines -Section $relocation.ToSection -Key $relocation.Setting -NewLines ([string[]]$relocation.DestinationLines)
                    $writeGameIni = $true
                }
                else {
                    throw "Blocked destination file for relocation: $($relocation.Setting)"
                }
            }

            $relocationsApplied.Add([pscustomobject]@{
                Setting     = $relocation.Setting
                FromTarget  = $relocation.FromTarget
                FromSection = $relocation.FromSection
                ToTarget    = $relocation.ToTarget
                ToSection   = $relocation.ToSection
                Value       = ($relocation.SourceValues -join ', ')
                Reason      = $relocation.Reason
            })
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Error   = $_.Exception.Message
            Changes = @()
        }
    }

    return [pscustomobject]@{
        Success               = $true
        Error                 = ''
        Changes               = $validated.Changes
        ChangesWithOldValues  = $changesWithOldValues.ToArray()
        RecipesApplied        = $recipesApplied.ToArray()
        RelocationsApplied    = $relocationsApplied.ToArray()
        GameUserSettingsPath  = $paths.GameUserSettings
        GameIniPath           = $paths.GameIni
        BackupRoot            = $paths.BackupRoot
        GameUserSettingsLines = $gameUserLines
        GameIniLines          = $gameIniLines
        WriteGameUserSettings = $writeGameUserSettings
        WriteGameIni          = $writeGameIni
    }
}

function Invoke-AsaAiApplyProposal {
    param([Parameter(Mandatory)]$Proposal)

    if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'ASA is running. Stop the server before applying AI settings.'
            BackupPath = ''
        }
    }

    $prepared = New-AsaAiPreparedApply -Proposal $Proposal
    if (-not $prepared.Success) {
        return [pscustomobject]@{
            Success    = $false
            Message    = $prepared.Error
            BackupPath = ''
        }
    }

    if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'ASA started while settings were being prepared. Nothing was written.'
            BackupPath = ''
        }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'
    $backupPath = Join-Path $prepared.BackupRoot ($timestamp + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $backupGameUserSettings = Join-Path $backupPath 'GameUserSettings.ini'
    $backupGameIni = Join-Path $backupPath 'Game.ini'

    try {
        [void][IO.Directory]::CreateDirectory($backupPath)
        [IO.File]::Copy($prepared.GameUserSettingsPath, $backupGameUserSettings, $false)
        [IO.File]::Copy($prepared.GameIniPath, $backupGameIni, $false)

        if (([IO.FileInfo]$prepared.GameUserSettingsPath).Length -ne ([IO.FileInfo]$backupGameUserSettings).Length) {
            throw 'GameUserSettings.ini backup verification failed.'
        }
        if (([IO.FileInfo]$prepared.GameIniPath).Length -ne ([IO.FileInfo]$backupGameIni).Length) {
            throw 'Game.ini backup verification failed.'
        }
    }
    catch {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'Backup failed; no configuration files were written. ' + $_.Exception.Message
            BackupPath = $backupPath
        }
    }

    if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return [pscustomobject]@{
            Success    = $false
            Message    = 'ASA started before writing. Backups exist, but no configuration files were written.'
            BackupPath = $backupPath
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writeItems = New-Object System.Collections.Generic.List[object]

    if ($prepared.WriteGameUserSettings) {
        $writeItems.Add([pscustomobject]@{
            Target = $prepared.GameUserSettingsPath
            Lines  = $prepared.GameUserSettingsLines
            Backup = $backupGameUserSettings
        })
    }
    if ($prepared.WriteGameIni) {
        $writeItems.Add([pscustomobject]@{
            Target = $prepared.GameIniPath
            Lines  = $prepared.GameIniLines
            Backup = $backupGameIni
        })
    }

    $tempPaths = New-Object System.Collections.Generic.List[string]
    $replaceBackups = New-Object System.Collections.Generic.List[string]
    $writeStarted = $false

    try {
        foreach ($item in $writeItems) {
            $directory = Split-Path -Parent $item.Target
            $tempPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($item.Target) + '.' + [guid]::NewGuid().ToString('N') + '.ai.tmp')
            [IO.File]::WriteAllLines($tempPath, [string[]]$item.Lines, $utf8NoBom)
            $item | Add-Member -NotePropertyName TempPath -NotePropertyValue $tempPath
            $tempPaths.Add($tempPath)
        }

        foreach ($item in $writeItems) {
            if (Get-Process -Name 'ArkAscendedServer' -ErrorAction SilentlyContinue | Select-Object -First 1) {
                throw 'ASA started during the apply operation.'
            }

            $replaceBackup = Join-Path (Split-Path -Parent $item.Target) ('.' + [IO.Path]::GetFileName($item.Target) + '.' + [guid]::NewGuid().ToString('N') + '.replace-backup.tmp')
            $replaceBackups.Add($replaceBackup)
            $writeStarted = $true
            [IO.File]::Replace($item.TempPath, $item.Target, $replaceBackup, $true)
        }
    }
    catch {
        $applyError = $_.Exception.Message
        $rollbackErrors = New-Object System.Collections.Generic.List[string]

        if ($writeStarted) {
            foreach ($pair in @(
                @{ Target = $prepared.GameUserSettingsPath; Backup = $backupGameUserSettings },
                @{ Target = $prepared.GameIniPath; Backup = $backupGameIni }
            )) {
                try {
                    $restoreTemp = Join-Path (Split-Path -Parent $pair.Target) ('.' + [IO.Path]::GetFileName($pair.Target) + '.' + [guid]::NewGuid().ToString('N') + '.restore.tmp')
                    [IO.File]::Copy($pair.Backup, $restoreTemp, $false)
                    $tempPaths.Add($restoreTemp)
                    $restoreDiscard = Join-Path (Split-Path -Parent $pair.Target) ('.' + [IO.Path]::GetFileName($pair.Target) + '.' + [guid]::NewGuid().ToString('N') + '.restore-backup.tmp')
                    $replaceBackups.Add($restoreDiscard)
                    [IO.File]::Replace($restoreTemp, $pair.Target, $restoreDiscard, $true)
                }
                catch {
                    $rollbackErrors.Add($_.Exception.Message)
                }
            }
        }

        $message = 'Apply failed. '
        if ($writeStarted -and $rollbackErrors.Count -eq 0) {
            $message += 'Both INI files were restored from the snapshot. '
        }
        elseif ($writeStarted) {
            $message += 'Automatic rollback had an error; use the snapshot path shown below to restore manually. '
        }
        else {
            $message += 'No configuration file was replaced. '
        }
        $message += $applyError

        return [pscustomobject]@{
            Success    = $false
            Message    = $message
            BackupPath = $backupPath
        }
    }
    finally {
        foreach ($path in @($tempPaths.ToArray()) + @($replaceBackups.ToArray())) {
            if ($path -and [IO.File]::Exists($path)) {
                try { [IO.File]::Delete($path) } catch { }
            }
        }
    }

    foreach ($change in $prepared.ChangesWithOldValues) {
        try {
            Add-AsaChangelogEntry -Key $change.Key -NewValue ([string]$change.Value) -OldValue ([string]$change.OldValue) -TargetFile $change.TargetFile -Reason $change.Reason -BackupPath $backupPath
        }
        catch { }
    }

    foreach ($recipe in $prepared.RecipesApplied) {
        try {
            Add-AsaChangelogEntry -Key ('ConfigOverrideItemCraftingCosts (' + $recipe.ItemName + ')') -NewValue $recipe.NewSummary -OldValue $recipe.OldSummary -TargetFile 'Game.ini' -Reason $recipe.Reason -BackupPath $backupPath
        }
        catch { }
    }

    foreach ($relocation in $prepared.RelocationsApplied) {
        try {
            Add-AsaChangelogEntry -Key $relocation.Setting -NewValue "moved to $($relocation.ToTarget) $($relocation.ToSection) (value $($relocation.Value) preserved)" -OldValue "was at $($relocation.FromTarget) $($relocation.FromSection)" -TargetFile $relocation.ToTarget -Reason $relocation.Reason -BackupPath $backupPath
        }
        catch { }
    }

    $recipeCount = @($prepared.RecipesApplied).Count
    $relocationCount = @($prepared.RelocationsApplied).Count
    $appliedParts = New-Object System.Collections.Generic.List[string]
    if ($prepared.Changes.Count -gt 0) { $appliedParts.Add("$($prepared.Changes.Count) validated setting(s)") }
    if ($recipeCount -gt 0) { $appliedParts.Add("$recipeCount custom recipe(s)") }
    if ($relocationCount -gt 0) { $appliedParts.Add("$relocationCount relocation(s)") }
    $messageText = if ($appliedParts.Count -gt 0) { 'Applied ' + ($appliedParts -join ' and ') + '.' } else { 'Nothing to apply.' }

    return [pscustomobject]@{
        Success     = $true
        Message     = $messageText
        BackupPath  = $backupPath
        Changes     = $prepared.Changes
        Recipes     = $prepared.RecipesApplied
        Relocations = $prepared.RelocationsApplied
    }
}

function Get-AsaAiKnownItemText {
    $kibbleNames = @('basic kibble', 'simple kibble', 'regular kibble', 'superior kibble', 'exceptional kibble', 'extraordinary kibble')
    $resourceNames = @('thatch', 'wood', 'stone', 'flint', 'metal', 'metal ingot', 'crystal', 'obsidian', 'clay', 'silica pearls', 'black pearls', 'cementing paste', 'chitin', 'keratin', 'hide', 'pelt', 'fiber', 'gasoline', 'gunpowder', 'sparkpowder', 'electronics', 'polymer', 'organic polymer', 'element', 'rare flower', 'rare mushroom', 'silk', 'charcoal', 'sap', 'oil', 'sand', 'sulfur')
    $foodNames = @('cooked meat', 'raw meat', 'cooked prime meat', 'raw prime meat', 'raw mutton', 'spoiled meat', 'mejoberry', 'narcoberry', 'stimberry', 'citronal', 'narcotic', 'stimulant', 'waterskin')
    $toolNames = @('stone hatchet', 'metal hatchet', 'stone pick', 'metal pick', 'torch', 'sickle')
    return @"
Kibble tiers: $($kibbleNames -join ', ')
Common resources: $($resourceNames -join ', ')
Common foods: $($foodNames -join ', ')
Common tools: $($toolNames -join ', ')
(Species-specific kibbles like "rex kibble" or "argentavis kibble" are also recognized even though not listed above.)
"@
}

function Get-AsaAiCurrentRecipeOverridesText {
    $paths = Get-AsaAiFixedConfigPaths
    $gameIniLines = if (Test-Path -LiteralPath $paths.GameIni) { [IO.File]::ReadAllLines($paths.GameIni) } else { @() }
    $lines = Get-AsaIniSectionRepeatedLines -Lines $gameIniLines -Section '[/Script/ShooterGame.ShooterGameMode]' -Key 'ConfigOverrideItemCraftingCosts'
    if (@($lines).Count -eq 0) { return '(none -- every item currently uses its vanilla recipe)' }

    $reverseMap = @{}
    foreach ($key in $script:AsaItemClassAliases.Keys) {
        $class = $script:AsaItemClassAliases[$key]
        if (-not $reverseMap.ContainsKey($class)) { $reverseMap[$class] = $key }
    }

    $summaries = foreach ($line in $lines) {
        $itemMatch = [regex]::Match($line, 'ItemClassString="(?<i>[^"]+)"')
        if (-not $itemMatch.Success) { continue }
        $class = $itemMatch.Groups['i'].Value
        $friendly = if ($reverseMap.ContainsKey($class)) { $reverseMap[$class] } else { $class }
        "- ${friendly}: " + (ConvertTo-AsaRecipeSummaryText -Line $line)
    }
    return ($summaries -join "`n")
}

# Phrases that deterministically identify which diagnostic finding category a
# request is talking about. Matching here NEVER touches the local model --
# it's a plain keyword check so a "fix the wrong-file findings" request can
# never be reinterpreted or have findings invented for it.
$script:AsaDiagnosticCategoryPhrases = [ordered]@{
    'WRONG TARGET FILE' = @('wrong target file', 'found in the wrong file', 'in the wrong file', 'wrong file')
    'WRONG SECTION'      = @('wrong section')
}

function Get-AsaAiReferencedDiagnosticCategories {
    <# Deterministic keyword match only -- never delegated to the model. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Prompt)

    $lower = $Prompt.ToLowerInvariant()
    $categories = New-Object System.Collections.Generic.List[string]
    foreach ($category in $script:AsaDiagnosticCategoryPhrases.Keys) {
        foreach ($phrase in $script:AsaDiagnosticCategoryPhrases[$category]) {
            if ($lower.Contains($phrase)) {
                if (-not $categories.Contains($category)) { [void]$categories.Add($category) }
                break
            }
        }
    }
    return $categories.ToArray()
}

function Get-AsaAiRelocationProposalFromDiagnostics {
    <#
    Builds a relocation-only proposal directly from the CURRENT diagnostic
    findings in the given categories -- no model call, no guessing which
    findings were meant. Only categories that represent a setting sitting in
    the wrong INI file/section are ever passed in here by the caller; each
    candidate is still independently re-validated by
    Get-AsaSettingRelocationPlan (support status, value validity, conflicts),
    so an unsafe finding is excluded even if it somehow slipped through.
    #>
    param([Parameter(Mandatory)][string[]]$Categories)

    $diagnostics = Invoke-AsaConfigDiagnostics
    $paths = Get-AsaAiFixedConfigPaths
    $guLines = if (Test-Path -LiteralPath $paths.GameUserSettings) { [IO.File]::ReadAllLines($paths.GameUserSettings) } else { @() }
    $giLines = if (Test-Path -LiteralPath $paths.GameIni) { [IO.File]::ReadAllLines($paths.GameIni) } else { @() }

    $candidateFindings = @($diagnostics.Findings | Where-Object { $Categories -contains $_.Category })
    $seen = @{}
    $relocations = New-Object System.Collections.Generic.List[object]
    $rejected = New-Object System.Collections.Generic.List[string]

    foreach ($finding in $candidateFindings) {
        $baseName = Get-AsaSettingBaseName -Key $finding.Key
        if ($seen.ContainsKey($baseName)) { continue }
        $seen[$baseName] = $true

        $plan = Get-AsaSettingRelocationPlan -SettingName $baseName -GameUserSettingsLines $guLines -GameIniLines $giLines
        if (-not $plan.Success) {
            $rejected.Add("Relocation refused for ${baseName}: $($plan.Error)")
            continue
        }
        $relocations.Add([pscustomobject]@{
            Setting          = $plan.Setting
            FromTarget       = $plan.FromTarget
            FromSection      = $plan.FromSection
            ToTarget         = $plan.ToTarget
            ToSection        = $plan.ToSection
            Repeatable       = $plan.Repeatable
            SourceLines      = $plan.SourceLines
            SourceValues     = $plan.SourceValues
            WriteDestination = $plan.WriteDestination
            DestinationLines = $plan.DestinationLines
            DestinationHadExisting = $plan.DestinationHadExisting
            Reason           = $plan.Reason
        })
    }

    $categoryText = $Categories -join ', '
    $summary = if ($relocations.Count -gt 0) {
        "Found $($relocations.Count) setting(s) currently misplaced per diagnostics ($categoryText) and proposed relocating each to its authoritative location, preserving its current value. No other settings were changed."
    }
    else {
        "No safely relocatable settings were found among the current $categoryText diagnostic findings."
    }

    return [pscustomobject]@{
        Summary     = $summary
        Changes     = @()
        Actions     = @()
        Recipes     = @()
        Relocations = $relocations.ToArray()
        Rejected    = $rejected.ToArray()
        ReadOnly    = $true
    }
}

function Get-AsaAiProposal {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model = 'qwen3:8b',
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
    )

    # A request that names a specific diagnostic category ("fix the WRONG
    # TARGET FILE findings") is resolved entirely deterministically against
    # the CURRENT diagnostics -- the local model never sees this request and
    # never decides which findings/settings/destinations are involved.
    $referencedCategories = Get-AsaAiReferencedDiagnosticCategories -Prompt $Prompt
    if ($referencedCategories.Count -gt 0) {
        return Get-AsaAiRelocationProposalFromDiagnostics -Categories $referencedCategories
    }

    $allowedKeys = [object[]]@($script:AllowedSettings.Keys)
    $allowedActionKeys = [object[]]@($script:AllowedActions.Keys)
    $schema = @{
        type = 'object'
        additionalProperties = $false
        properties = @{
            summary = @{ type = 'string' }
            changes = @{
                type = 'array'
                items = @{
                    type = 'object'
                    additionalProperties = $false
                    properties = @{
                        key    = @{ type = 'string'; enum = $allowedKeys }
                        value  = @{ type = 'string' }
                        reason = @{ type = 'string' }
                    }
                    required = @('key','value','reason')
                }
            }
            actions = @{
                type = 'array'
                items = @{
                    type = 'object'
                    additionalProperties = $false
                    properties = @{
                        name   = @{ type = 'string'; enum = $allowedActionKeys }
                        reason = @{ type = 'string' }
                    }
                    required = @('name','reason')
                }
            }
            recipes = @{
                type = 'array'
                items = @{
                    type = 'object'
                    additionalProperties = $false
                    properties = @{
                        item      = @{ type = 'string' }
                        resources = @{
                            type = 'array'
                            items = @{
                                type = 'object'
                                additionalProperties = $false
                                properties = @{
                                    resource = @{ type = 'string' }
                                    amount   = @{ type = 'string' }
                                }
                                required = @('resource','amount')
                            }
                        }
                        reason = @{ type = 'string' }
                    }
                    required = @('item','resources','reason')
                }
            }
            relocations = @{
                type = 'array'
                items = @{
                    type = 'object'
                    additionalProperties = $false
                    properties = @{
                        setting = @{ type = 'string' }
                        reason  = @{ type = 'string' }
                    }
                    required = @('setting','reason')
                }
            }
        }
        required = @('summary','changes','actions','recipes','relocations')
    }

    $allowedText = Get-AsaAiAllowedSettingText
    $allowedActionText = Get-AsaAiAllowedActionText
    $knownItemText = Get-AsaAiKnownItemText
    $currentRecipeText = Get-AsaAiCurrentRecipeOverridesText
    $systemPrompt = @"
You are the settings and operations assistant for a private ARK: Survival Ascended dedicated server.
You may ONLY propose settings from the allow-list below, ONLY trigger operations from the allow-list of actions below, and ONLY propose custom crafting recipes using item/resource names from the known items list below. Never propose shell commands, PowerShell, file operations, passwords, paths, mods, firewall changes, deletes, or arbitrary INI keys, actions, or item class strings.
Return only JSON matching the supplied schema.
Every numeric value must be a plain invariant decimal string such as "4", "0.5", or "12.0". Do not include x, %, units, or explanatory text in value.
If the request cannot be satisfied using only the allow-lists, return empty changes/actions/recipes/relocations arrays and explain why in summary.
Use "relocations" ONLY when the user names a specific setting that is currently stored in the wrong INI file or section and should be moved to its correct location (e.g. "move PassiveTameIntervalMultiplier to the right file"). In each relocation entry, "setting" is just the setting's name -- never guess or state a destination file or section yourself; the correct location is always looked up from the server's own knowledge base and verified independently, not decided by you. If the setting isn't actually misplaced, isn't a known supported setting, or you are not sure, leave relocations empty and explain why in summary instead of guessing.
Each allowed setting below shows its CURRENT VALUE, which is the server's actual live value right now, not a vanilla default. For any relative request (boost/increase/lower/reduce/further/more/less/faster/slower/higher/lower), you MUST calculate the new value starting from that CURRENT VALUE, never from 1.0 or any other assumed baseline. Example: if a setting's CURRENT VALUE is 30.2 and the user asks to "boost it further", propose something meaningfully above 30.2 (for example 40 or 45), never a small number like 2 just because it looks like a big multiplier in isolation -- 2 would be a severe cut from 30.2, not a boost. If you are not given a specific target number, pick a value roughly 20-50% above (or below, for a reduction request) the CURRENT VALUE shown, staying within the allowed range.
When a user asks for shorter nights, increase NightTimeSpeedScale. When a user asks for longer days, decrease DayTimeSpeedScale.
When wild dinos feel too high-level or too tanky/aggressive, decrease OverrideOfficialDifficulty (and optionally PerLevelStatsMultiplier_DinoWild[0]/[8] to soften their health/damage growth per level), rather than touching an unrelated setting.
When a player says leveling up doesn't feel impactful, raise the relevant PerLevelStatsMultiplier_Player[N] instead of XPMultiplier (XP only controls how fast you reach a level, not what each level gives you).
When a user asks to start, stop, restart, update, or back up the server, use the matching action instead of a setting. You do not need to separately request a stop or start around a settings change: the system already stops the server before writing settings and restarts it afterward if it was running.
Use "recipes" ONLY when the user asks to change what an item costs to craft (e.g. "make regular kibble cost only 5 cooked meat", "reduce the metal cost of a hatchet"). In each recipe entry, "item" is always the finished product being crafted (the thing whose cost is changing) -- it is NEVER one of its own ingredients. "resources" is the COMPLETE ingredient list that item will require after the change (each entry replaces the item's entire ingredient list, so list every resource it should need, not just the one the user mentioned). If the user's wording implies a full replacement ("only", "instead of"), give just the resource(s) they named. If they ask to add to or adjust one ingredient of an item that already has a custom recipe shown below, keep "item" as that same item and carry its other current ingredients (from the list below) into "resources" unchanged, adding or changing only the one named -- do NOT change "item" to the ingredient's name. Worked example: request "basic kibble should also need 2 fiber, on top of what it already requires" where the current override below shows "basic kibble: PrimalItemConsumable_CookedMeat_C x5.0" -> correct recipe entry is {"item": "basic kibble", "resources": [{"resource": "cooked meat", "amount": "5"}, {"resource": "fiber", "amount": "2"}], "reason": "..."} -- item stays "basic kibble", never becomes "cooked meat" or "fiber". Use "item" and "resource" values EXACTLY as spelled in the known items list below (e.g. "regular kibble", "cooked meat") -- never invent a name that is not listed and never use a raw game class string. "amount" must be a plain invariant decimal string like "5" or "2.5". If the requested item or resource is not in the known list, leave recipes empty and explain why in summary instead of guessing a name.

Known items and resources for custom recipes:
$knownItemText

Current custom recipe overrides already in effect (empty means every item still uses its vanilla recipe):
$currentRecipeText

Allowed settings:
$allowedText

Allowed actions:
$allowedActionText
"@

    $body = @{
        model = $Model
        stream = $false
        format = $schema
        options = @{ temperature = 0 }
        messages = @(
            @{ role = 'system'; content = $systemPrompt },
            @{ role = 'user'; content = $Prompt }
        )
    }

    $uri = $OllamaBaseUrl.TrimEnd('/') + '/api/chat'
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 20)
    }
    catch {
        throw "Could not reach local Ollama at $uri. Start Ollama and confirm the model '$Model' is installed. $($_.Exception.Message)"
    }

    $content = [string]$response.message.content
    if (-not $content) {
        throw 'Ollama returned no structured response content.'
    }

    try {
        $rawProposal = $content | ConvertFrom-Json
    }
    catch {
        throw "Ollama returned invalid JSON. No changes were made. Raw response: $content"
    }

    return ConvertTo-AsaValidatedProposal -RawProposal $rawProposal
}

function Invoke-AsaAiRequest {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model = 'qwen3:8b',
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
    )

    $proposal = Get-AsaAiProposal -Prompt $Prompt -Model $Model -OllamaBaseUrl $OllamaBaseUrl
    $steps = New-Object System.Collections.Generic.List[object]

    $hasChanges = (@($proposal.Changes).Count -gt 0) -or (@($proposal.Recipes).Count -gt 0) -or (@($proposal.Relocations).Count -gt 0)
    $requestedActionNames = @($proposal.Actions | ForEach-Object { $_.Name })
    $hasRestoringAction = @('StartServer', 'Restart', 'UpdateAndRestart', 'SafeBackup') | Where-Object { $requestedActionNames -contains $_ }

    $wasRunningBeforeChanges = $false
    $stoppedOk = $true
    if ($hasChanges) {
        $wasRunningBeforeChanges = [bool](Get-AsaAiRunningServerProcess)
        if ($wasRunningBeforeChanges) {
            $stopResult = Invoke-AsaAiServerAction -Action 'SafeStop'
            $stoppedOk = $stopResult.Success
            $steps.Add([pscustomobject]@{ Step = 'Stop before settings change'; Success = $stopResult.Success; Message = $stopResult.Message })
        }

        if ($stoppedOk) {
            $applyResult = Invoke-AsaAiApplyProposal -Proposal $proposal
            $steps.Add([pscustomobject]@{ Step = 'Apply settings'; Success = $applyResult.Success; Message = $applyResult.Message })
        }
        else {
            $steps.Add([pscustomobject]@{ Step = 'Apply settings'; Success = $false; Message = 'Skipped because the safe stop before writing settings did not succeed.' })
        }
    }

    foreach ($action in @($proposal.Actions)) {
        $result = Invoke-AsaAiServerAction -Action $action.Name
        $steps.Add([pscustomobject]@{ Step = "Action: $($action.Name)"; Success = $result.Success; Message = $result.Message })
    }

    if ($hasChanges -and $stoppedOk -and $wasRunningBeforeChanges -and -not $hasRestoringAction) {
        $startResult = Invoke-AsaAiServerAction -Action 'StartServer'
        $steps.Add([pscustomobject]@{ Step = 'Restart after settings change'; Success = $startResult.Success; Message = $startResult.Message })
    }

    return [pscustomobject]@{
        Summary     = $proposal.Summary
        Changes     = $proposal.Changes
        Actions     = $proposal.Actions
        Recipes     = $proposal.Recipes
        Relocations = $proposal.Relocations
        Rejected    = $proposal.Rejected
        Steps       = $steps.ToArray()
    }
}

function Test-AsaAiConnection {
    param(
        [string]$Model = 'qwen3:8b',
        [string]$OllamaBaseUrl = 'http://127.0.0.1:11434'
    )

    $steps = New-Object System.Collections.Generic.List[object]
    $baseUrl = $OllamaBaseUrl.TrimEnd('/')

    try {
        $tags = Invoke-RestMethod -Uri "$baseUrl/api/tags" -Method Get -TimeoutSec 10
        $steps.Add([pscustomobject]@{ Step = 'Ollama reachable'; Success = $true; Message = "Connected to $baseUrl." })
    }
    catch {
        $steps.Add([pscustomobject]@{ Step = 'Ollama reachable'; Success = $false; Message = "Could not reach Ollama at $baseUrl. Is Ollama running? $($_.Exception.Message)" })
        return [pscustomobject]@{ Success = $false; Steps = $steps.ToArray() }
    }

    $installedModels = @($tags.models | ForEach-Object { [string]$_.name })
    $modelPresent = $installedModels -contains $Model -or (@($installedModels | Where-Object { $_ -like "$Model*" })).Count -gt 0
    if ($modelPresent) {
        $steps.Add([pscustomobject]@{ Step = 'Model installed'; Success = $true; Message = "Model '$Model' is available." })
    }
    else {
        $installedText = if ($installedModels.Count -gt 0) { $installedModels -join ', ' } else { '(none installed)' }
        $steps.Add([pscustomobject]@{ Step = 'Model installed'; Success = $false; Message = "Model '$Model' was not found. Installed: $installedText. Run: ollama pull $Model" })
        return [pscustomobject]@{ Success = $false; Steps = $steps.ToArray() }
    }

    try {
        $proposal = Get-AsaAiProposal -Prompt 'Set XP to 2' -Model $Model -OllamaBaseUrl $OllamaBaseUrl
        if (@($proposal.Changes).Count -gt 0) {
            $change = @($proposal.Changes)[0]
            $steps.Add([pscustomobject]@{ Step = 'Round-trip test'; Success = $true; Message = "Model responded correctly: proposed $($change.Key) = $($change.Value). Nothing was written (preview only)." })
        }
        else {
            $steps.Add([pscustomobject]@{ Step = 'Round-trip test'; Success = $false; Message = "Model responded but did not propose the expected setting. Raw summary: $($proposal.Summary)" })
            return [pscustomobject]@{ Success = $false; Steps = $steps.ToArray() }
        }
    }
    catch {
        $steps.Add([pscustomobject]@{ Step = 'Round-trip test'; Success = $false; Message = "Model call failed: $($_.Exception.Message)" })
        return [pscustomobject]@{ Success = $false; Steps = $steps.ToArray() }
    }

    return [pscustomobject]@{ Success = $true; Steps = $steps.ToArray() }
}

if ($TestConnection) {
    Test-AsaAiConnection -Model $Model -OllamaBaseUrl $OllamaBaseUrl | ConvertTo-Json -Depth 6
}
elseif ($Diagnose) {
    Invoke-AsaConfigDiagnostics | ConvertTo-Json -Depth 8
}
elseif ($Question) {
    Get-AsaAiKnowledgeAnswer -Question $Question -Model $Model -OllamaBaseUrl $OllamaBaseUrl | ConvertTo-Json -Depth 8
}
elseif ($Prompt -and $Execute) {
    Invoke-AsaAiRequest -Prompt $Prompt -Model $Model -OllamaBaseUrl $OllamaBaseUrl | ConvertTo-Json -Depth 8
}
elseif ($Prompt) {
    Get-AsaAiProposal -Prompt $Prompt -Model $Model -OllamaBaseUrl $OllamaBaseUrl | ConvertTo-Json -Depth 8
}
