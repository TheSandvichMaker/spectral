RectF32 :: struct
{
    x0: float;
    y0: float;
    x1: float;
    y1: float;

#place x0;
    min: Vector2;

#place x1;
    max: Vector2;
}

RectS32 :: struct
{
    x0: s32;
    y0: s32;
    x1: s32;
    y1: s32;
}

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

square_root :: (input: float) -> float #must
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

reflect :: inline (v: Vector3, n: Vector3) -> Vector3 #must
{
    return v - n*dot(v, n)*2;
}

refract :: inline (d: Vector3, n: Vector3, cos_theta_i: float, cos_theta_t: float, eta_i_over_eta_t: float) -> Vector3
{
    result := eta_i_over_eta_t*d + n*(eta_i_over_eta_t*cos_theta_i - cos_theta_t);
    return result;
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

view_matrix :: (x: Vector3, y: Vector3, z: Vector3, p: Vector3) -> Matrix4
{
    result := make_matrix_from_rows(x, y, z);
    result  = translate(result, -p);
    return result;
}

view_matrix :: (p: Vector3, d: Vector3, up := WORLD_UP) -> Matrix4
{
    x, y, z := basis_vectors(d, up);
    return view_matrix(x, y, z, p);
}

projection_matrix :: (vfov_in_degrees: float, aspect_ratio: float, near_plane: float) -> Matrix4
{
    g := 1.0 / tan(to_radians(0.5*vfov_in_degrees));
    s := aspect_ratio;
    n := near_plane;

    e := 0.000001;

    result := make_matrix4(
        g/s, 0, 0, 0,
        0,   g, 0, 0,
        0,   0, e, n*(1-e),
        0,   0,-1, 0,
    );
    return result;
}
