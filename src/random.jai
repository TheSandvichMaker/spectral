Random_Series :: struct
{
    state: u32 = 0xCAFEBABE;
}

next :: (r: *Random_Series) -> u32
{
    x := r.state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    r.state = x;
    return x;
}

// returns random [0, 1) float
random_unilateral :: (r: *Random_Series) -> float
{
    // NOTE: Stolen from rnd.h, courtesy of Jonatan Hedborg
    exponent: u32 = 127;
    mantissa := next(r) >> 9;
    bits := (exponent << 23) | mantissa;
    result := << cast(*float)*bits - 1.0;
    return result;
}

// returns random [-1, 1) float
random_bilateral :: (r: *Random_Series) -> float
{
    return -1.0 + 2.0*random_unilateral(r);
}

// returns random number in range [0, range)
random_choice :: (r: *Random_Series, range: u32) -> u32
{
    result := next(r) % range;
    return result;
}

// returns random number in range [1, sides]
dice_roll :: (r: *Random_Series, sides: u32) -> u32
{
    result := 1 + random_choice(r, sides);
    return result;
}

// returns random number in range [min, max]
random_range :: (r: *Random_Series, min: s32, max: s32) -> s32
{
    if max < min  max = min;

    result := min + cast(s32)next(r) % (max - min + 1);
    return result;
}

// returns random float in range [min, max)
random_range :: (r: *Random_Series, min: float, max: float) -> float
{
    range := random_unilateral(r);
    result := min + range*(max - min);
    return result;
}

random_unilateral2 :: inline (r: *Random_Series) -> Vector2
{
    result: Vector2 = ---;
    result.x = random_unilateral(r);
    result.y = random_unilateral(r);
    return result;
}

random_unilateral3 :: inline (r: *Random_Series) -> Vector3
{
    result: Vector3 = ---;
    result.x = random_unilateral(r);
    result.y = random_unilateral(r);
    result.z = random_unilateral(r);
    return result;
}

random_in_unit_square :: (r: *Random_Series) -> Vector2
{
    result: Vector2 = ---;
    result.x = random_bilateral(r);
    result.y = random_bilateral(r);
    return result;
}

random_in_unit_cube :: (r: *Random_Series) -> Vector3
{
    result: Vector3 = ---;
    result.x = random_bilateral(r);
    result.y = random_bilateral(r);
    result.z = random_bilateral(r);
    return result;
}

random_in_unit_disk :: (r: *Random_Series) -> Vector2
{
    result: Vector2 = ---;
    while true
    {
        result = random_in_unit_square(r);
        if dot(result, result) < 1.0
        {
            break;
        }
    }
    return result;
}

random_in_unit_sphere :: (r: *Random_Series) -> Vector3
{
    result: Vector3 = ---;
    while true
    {
        result = random_in_unit_cube(r);
        if dot(result, result) < 1.0
        {
            break;
        }
    }
    return result;
}

