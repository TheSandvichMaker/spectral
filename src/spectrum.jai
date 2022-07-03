#if USE_SAMPLED_SPECTRUM
{
    Spectrum :: Sampled_Spectrum;
}
else
{
    Spectrum :: RGB_Spectrum;
}

Spectrum_Base :: struct(SAMPLE_COUNT: int)
{
    c: [SAMPLE_COUNT] float;
}

RGB_Spectrum :: struct
{
    using base: Spectrum_Base(SAMPLE_COUNT = 3);
}

Sampled_Spectrum :: struct
{
    SAMPLED_LAMBDA_START :: 400;
    SAMPLED_LAMBDA_END   :: 700;

    using base: Spectrum_Base(SAMPLE_COUNT = 60);
}

make_spectrum :: inline (v := 0.0) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..Spectrum.SAMPLE_COUNT-1
    {
        result.c[i] = v;
    }
    return result;
}

operator + :: inline (a: Spectrum, b: Spectrum) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..Spectrum.SAMPLE_COUNT-1
    {
        result.c[i] = a.c[i] + b.c[i];
    }
    return result;
}

operator - :: inline (a: Spectrum, b: Spectrum) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..Spectrum.SAMPLE_COUNT-1
    {
        result.c[i] = a.c[i] - b.c[i];
    }
    return result;
}

operator * :: inline (a: Spectrum, b: Spectrum) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..Spectrum.SAMPLE_COUNT-1
    {
        result.c[i] = a.c[i] * b.c[i];
    }
    return result;
}

operator / :: inline (a: Spectrum, b: Spectrum) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..Spectrum.SAMPLE_COUNT-1
    {
        result.c[i] = a.c[i] / b.c[i];
    }
    return result;
}

operator == :: inline (a: Spectrum, b: Spectrum) -> bool
{
    for i: 0..Spectrum.SAMPLE_COUNT-1
    {
        if a.c[i] != b.c[i] then return false;
    }
    return true;
}

is_black :: inline (sp: Spectrum) -> bool
{
    for i: 0..sp.SAMPLE_COUNT-1
    {
        if sp.c[i] != 0.0 then return false;
    }
    return true;
}

square_root :: inline (sp: Spectrum) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..sp.SAMPLE_COUNT-1
    {
        result.c[i] = square_root(sp.c[i]);
    }
    return result;
}

pow :: inline (sp: Spectrum, e: float) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..sp.SAMPLE_COUNT-1
    {
        result.c[i] = pow(sp.c[i], e);
    }
    return result;
}

exp :: inline (sp: Spectrum) -> Spectrum
{
    result: Spectrum = ---;
    for i: 0..sp.SAMPLE_COUNT-1
    {
        result.c[i] = exp(sp.c[i]);
    }
    return result;
}
