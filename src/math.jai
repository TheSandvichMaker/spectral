frac :: inline (x: float) -> float #must
{
    return x - floor(x);
}

to_radians :: inline (deg: float) -> float #must
{
    return deg*(PI / 180.0);
}

to_degrees :: inline (rad: float) -> float #must
{
    return rad*(180.0 / PI);
}

sign_of :: inline(x: float) -> float #must
{
    if x >= 0.0  return  1.0;
    else         return -1.0;
}

square_root :: inline (input: float) -> float #must
{
    input_addr := *input;

    result: float = ---;
    result_addr := *result;

    #asm
    {
        sqrtss result_vec:, [input_addr];
        movss [result_addr], result_vec;
    }

    return result;
}

operator / :: (a: Vector3, b: Vector3) -> Vector3 #must
{
    result: Vector3 = ---;
    result.x = a.x / b.x;
    result.y = a.y / b.y;
    result.z = a.z / b.z;
    return result;
}

reflect :: inline (v: Vector3, n: Vector3) -> Vector3 #must
{
    return v - n*dot(v, n)*2;
}

Transform :: struct
{
    forward: Matrix4;
    inverse: Matrix4;
}

copy_sign :: (x: float, s: float) -> float
{
    SIGN_MASK :: 1 << 31;

    x_int := transmute(x, u32);
    s_int := transmute(s, u32);

    result := transmute((x_int & ~SIGN_MASK) | (s_int & SIGN_MASK), float);
    return result;
}

get_tangents :: (n: Vector3) -> t: Vector3, b: Vector3, n: Vector3
{
    sign := copy_sign(1.0, n.z);
    a := -1.0 / (sign + n.z);
    b := n.x*n.y*a;
    b0 := make_vector3(1.0 + sign*n.x*n.x*a, sign*b, -sign*n.x);
    b1 := make_vector3(b, sign + n.y*n.y*a, -n.y);
    return b0, b1, n;
}

orient_around_normal :: (v: Vector3, n: Vector3) -> Vector3
{
    t, b, n := get_tangents(n);

    result := b*v.x + n*v.y + t*v.z;
    return result;
}

map_to_unit_sphere :: (sample: Vector2) -> Vector3
{
    z := 1.0 - 2.0*sample.x;
    r := square_root(max(0.0, 1.0 - z*z));
    phi := TAU*sample.y;

    result: Vector3 = ---;
    result.x = cos(phi)*r;
    result.y = sin(phi)*r;
    result.z = z;

    return result;
}

map_to_hemisphere :: (sample: Vector2) -> Vector3
{
    azimuth := TAU*sample.x;
    y       := sample.y;
    a       := square_root(1.0 - y*y);

    result: Vector3 = ---;
    result.x = cos(azimuth)*a;
    result.y = y;
    result.z = sin(azimuth)*a;

    return result;
}

map_to_cosine_weighted_hemisphere :: (sample: Vector2) -> Vector3
{
    azimuth := TAU*sample.x;
    y       := sample.y;
    a       := square_root(1.0 - y);

    result: Vector3 = ---;
    result.x = cos(azimuth)*a;
    result.y = square_root(y);
    result.z = sin(azimuth)*a;

    return result;
}
