#pragma once
#include "Commandlets/Commandlet.h"
#include "GameFramework/Pawn.h"
#include "AbilitySystemInterface.h"
#include "EnhancedInputSubsystems.h"
#include "AutoSwitchWeaponBuildCommandlet.generated.h"

UCLASS()
class UAutoSwitchWeaponBuildCommandlet : public UCommandlet
{
    GENERATED_BODY()
public:
    virtual int32 Main(const FString& Params) override;
};

// Editor-only fixtures execute the actual generated Blueprint in a test world.
UCLASS()
class AAutoSwitchWeaponTestPawn : public APawn, public IAbilitySystemInterface
{
    GENERATED_BODY()
public:
    AAutoSwitchWeaponTestPawn();
    UPROPERTY() TObjectPtr<UAbilitySystemComponent> ASC;
    virtual UAbilitySystemComponent* GetAbilitySystemComponent() const override { return ASC; }
};

UCLASS()
class UAutoSwitchWeaponTestInput : public UEnhancedInputLocalPlayerSubsystem
{
    GENERATED_BODY()
public:
    int32 Requests = 0;
    virtual void InjectInputForAction(const UInputAction* Action, FInputActionValue RawValue,
        const TArray<UInputModifier*>& Modifiers, const TArray<UInputTrigger*>& Triggers) override;
};
