WORLD_UP :: Vector3.{0, 1, 0};
WRITE_DEBUG_RECORDS :: false;

Material :: struct
{
    color: Vector3;
}

Primitive :: struct
{
    using Kind :: enum u16
    {
        None;
        Plane;
        Sphere;
        Box;
    }

    material_index: s16;
    kind: Kind;
}

Plane :: struct
{
    using primitive: Primitive;
    kind = .Plane;

    d: float;
    n: Vector3;
}

Sphere :: struct
{
    using primitive: Primitive;
    kind = .Sphere;

    p: Vector3;
    r: float;
}

Box :: struct
{
    using primitive: Primitive;
    kind = .Box;

    p: Vector3;
    r: Vector3;
}

Camera :: struct
{
    p: Vector3;
    d: Vector3;
    fov: float; // vertical fov in degrees
}

basis_vectors :: (d: Vector3, up := WORLD_UP) -> x: Vector3, y: Vector3, z: Vector3
{
    z := -d;
    x := cross(up, z);
    y := cross(z, x);
    return x, y, z;
}

Ray :: struct
{
    o: Vector3;
    d: Vector3;
    inv_d: Vector3;
}

make_ray :: (o: Vector3, d: Vector3) -> Ray
{
    ray: Ray;
    ray.o = o;
    ray.d = d;
    ray.inv_d = 1.0 / d;
    return ray;
}

Scene :: struct
{
    planes:    [..] Plane;
    spheres:   [..] Sphere;
    boxes:     [..] Box;
    materials: [..] Material;

    debug_records: Intersect_Debug_Records;
}

Intersect_Record :: struct
{
    o:             Vector3;
    d:             Vector3;
    hit_p:         Vector3;
    hit_primitive: *Primitive;
}

Intersect_Records_Level :: struct
{
    hit:    [..] Intersect_Record;
    shadow: [..] Intersect_Record;
}

Intersect_Debug_Records :: struct
{
    current_level: int;
    levels: [256] Intersect_Records_Level;
}

add_primitive :: (using scene: *Scene, primitive: $T/Primitive)
{
    #if T == Sphere  array_add(*spheres, primitive);
    #if T == Box     array_add(*boxes, primitive);
    #if T == Plane   array_add(*planes, primitive);
}

add_material :: (using scene: *Scene, material: Material) -> s16
{
    result := cast(s16) materials.count;
    array_add(*materials, material);
    return result;
}

Tile :: struct
{
    x0: int;
    y0: int;
    x1: int;
    y1: int;
};

render_scene :: (camera: Camera, scene: *Scene, acc: Accumulation_Buffer, tile: Tile, frame_index: int)
{
    camera_x, camera_y, camera_z := basis_vectors(camera.d);

    w := cast(float) acc.w;
    h := cast(float) acc.h;

    film_w := w / h;
    film_h := 1.0;

    half_film_w := 0.5*film_w;
    half_film_h := 0.5*film_h;

    inv_half_film_w := 1.0 / half_film_w;
    inv_half_film_h := 1.0 / half_film_h;

    pixel_w := 1.0 / w;
    pixel_h := 1.0 / h;

    film_distance := film_h / tan(to_radians(camera.fov));

    random: Random_Series;
    random.state = xx (frame_index*(tile.x1 + 1000*tile.y1));

    for y: tile.y0..tile.y1-1
    {
        v := 1.0 - 2.0*(cast(float) y / h);

        for x: tile.x0..tile.x1-1
        {
            u := -1.0 + 2.0*(cast(float) x / w);

            p := camera.p;

            film_o := -camera_z * film_distance;

            jitter_x := 0.5*random_bilateral(*random);
            jitter_y := 0.5*random_bilateral(*random);

            film_p := film_o;
            film_p += (u + pixel_w*jitter_x)*half_film_w*camera_x;
            film_p += (v + pixel_h*jitter_y)*half_film_h*camera_y;

            d := normalize(film_p);

            r := make_ray(p, d);

            color := integrate_scene(scene, r, *random);
            color.x += 1.0 / 255.0;
            color.y += 1.0 / 255.0;
            color.z += 1.0 / 255.0;
            color = saturate(color);

            << get_texel(acc, x, y) += make_vector3(color.x, color.y, color.z);
        }
    }
}

MAX_BOUNCES :: 8;

integrate_scene :: (using scene: Scene, in_ray: Ray, random: *Random_Series) -> Vector3
{
    throughput := Vector3.{1, 1, 1};
    color      := Vector3.{0, 0, 0};

    ray := in_ray;

    for 0..MAX_BOUNCES-1
    {
        t, primitive := intersect_scene(scene, ray);

        if primitive
        {
            hit_p  := ray.o + t*ray.d;
            n := inline get_normal(primitive, hit_p);

            material := *materials[primitive.material_index];
            brdf := material.color*(1.0 / PI);

            throughput *= brdf;

            e := random_in_unit_square(random);
            r := orient_around_normal(map_to_hemisphere(e), n);

            ray = make_ray(hit_p + EPSILON*n, r);

            throughput *= dot(ray.d, n);
            throughput *= 2*PI;
        }
        else
        {
            sky_top := make_vector3(0.2, 0.3, 0.8);
            sky_bot := make_vector3(0.5, 0.7, 0.9);
            sky_col := lerp(sky_bot, sky_top, saturate(ray.d.y));

            color += throughput*sky_col;

            break;
        }
    }

    return color;
}

intersect_scene :: (using scene: Scene, r: Ray, $shadow_ray := false) -> float, *Primitive
{
    t := FLOAT32_MAX;

    primitive: *Primitive;

    for *p: planes
    {
        hit_t := inline intersect_plane(p, r);
        if hit_t < t
        {
            primitive = p;
            t = hit_t;

            #if shadow_ray  return t, primitive;
        }
    }

    for *s: spheres
    {
        hit_t := inline intersect_sphere(s, r);
        if hit_t < t
        {
            primitive = s;
            t = hit_t;

            #if shadow_ray  return t, primitive;
        }
    }

    for *b: boxes
    {
        hit_t := inline intersect_box(b, r);
        if hit_t < t
        {
            primitive = b;
            t = hit_t;

            #if shadow_ray  return t, primitive;
        }
    }

    #if WRITE_DEBUG_RECORDS
    {
        level := *debug_records.levels[debug_records.current_level];

        #if shadow_ray
        {
            records := *level.hit;
        }
        else
        {
            records := *level.shadow;
        }

        record := array_add(records);
        record.o             = r.o;
        record.d             = r.d;
        record.hit_p         = r.o + t*r.d;
        record.hit_primitive = primitive;
    }

    return t, primitive;
}

intersect_plane :: inline (p: *Plane, r: Ray) -> float
{
    t := (p.d - dot(p.n, r.o)) / dot(p.n, r.d);
    if t > EPSILON  return t;
    else            return FLOAT32_MAX;
}

intersect_sphere :: inline (s: *Sphere, r: Ray) -> float
{
    m := r.o - s.p;
    b := dot(m, r.d);
    c := dot(m, m) - s.r*s.r;

    if c > 0.0 && b > 0.0 then return FLOAT32_MAX;

    discr := b*b - c;

    if discr < 0.0 then return FLOAT32_MAX;

    t := -b - square_root(discr);

    if t < 0.0 then t = 0.0;

    return t;
}

intersect_box :: inline (b: *Box, r: Ray) -> float
{
    b_min := b.p - b.r;
    b_max := b.p + b.r;

    tx1 := r.inv_d.x*(b_min.x - r.o.x);
    tx2 := r.inv_d.x*(b_max.x - r.o.x);
    
    t_min := max(0.0, min(tx1, tx2));
    t_max := max(tx1, tx2);

    ty1 := r.inv_d.y*(b_min.y - r.o.y);
    ty2 := r.inv_d.y*(b_max.y - r.o.y);

    t_min = max(t_min, min(ty1, ty2));
    t_max = min(t_max, max(ty1, ty2));

    tz1 := r.inv_d.z*(b_min.z - r.o.z);
    tz2 := r.inv_d.z*(b_max.z - r.o.z);

    t_min = max(t_min, min(tz1, tz2));
    t_max = min(t_max, max(tz1, tz2));

    if t_max >= t_min return t_min;
    else              return FLOAT32_MAX;
}

get_normal :: inline (primitive: *Primitive, hit_p: Vector3) -> Vector3
{
    normal: Vector3 = ---;

    if primitive.kind ==
    {
        case .Plane;
            p := cast(*Plane) primitive;
            normal = p.n;

        case .Sphere;
            s := cast(*Sphere) primitive;
            normal = normalize(hit_p - s.p);

        case .Box;
            b := cast(*Box) primitive;
            rel_p := (hit_p - b.p) / b.r;

            e := 0;
            n := abs(rel_p);

            if n.y > n.component[e]  e = 1;
            if n.z > n.component[e]  e = 2;

            normal = make_vector3(0, 0, 0);
            normal.component[e] = sign_of(rel_p.component[e]);

        case;
            assert(false, "This shouldn't happen");
    }

    return normal;
}

#scope_file

EPSILON :: 0.0001;
