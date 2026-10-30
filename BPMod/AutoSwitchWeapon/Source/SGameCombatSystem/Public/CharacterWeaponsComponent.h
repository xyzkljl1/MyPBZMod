#pragma once
#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "GameplayTagContainer.h"
#include "CharacterWeaponsComponent.generated.h"

// These signatures reference PBZ's existing native functions when cooked.
UCLASS(BlueprintType)
class SGAMECOMBATSYSTEM_API UCharacterWeaponsComponent : public UActorComponent
{
    GENERATED_BODY()
public:
    UFUNCTION(BlueprintPure) float GetCurrentChangeWeaponCooldown(const FGameplayTag& SlotTag) const { return TestCooldown; }
    UFUNCTION(BlueprintPure) int32 GetSlotWeapons(const FGameplayTag& SlotTag) const { return TestWeapons; }
    UFUNCTION(BlueprintPure) bool IsInWeaponTransition() const { return TestTransition; }
    float TestCooldown = 0;
    int32 TestWeapons = 2;
    bool TestTransition = false;
};
