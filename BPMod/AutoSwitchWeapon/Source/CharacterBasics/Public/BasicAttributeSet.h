#pragma once
#include "CoreMinimal.h"
#include "AttributeSet.h"
#include "BasicAttributeSet.generated.h"

// Authoring declarations only. The game supplies this native class at runtime.
// No instance of this stub, or its module DLL, is included in the release.
UCLASS(BlueprintType)
class CHARACTERBASICS_API UBasicAttributeSet : public UAttributeSet
{
    GENERATED_BODY()
public:
    UPROPERTY(EditAnywhere, BlueprintReadWrite) FGameplayAttributeData Health;
    UPROPERTY(EditAnywhere, BlueprintReadWrite) FGameplayAttributeData Shachi;
    UPROPERTY(EditAnywhere, BlueprintReadWrite) FGameplayAttributeData Shachi_Max;
};
