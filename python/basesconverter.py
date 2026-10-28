BASES = {"2": 2, "8": 8, "10": 10, "16": 16}

def convertir(texte, base):
    n = int(texte, base)  # convertit le texte en nombre décimal
    print(f"Binaire     : {bin(n)[2:]}")
    print(f"Octal       : {oct(n)[2:]}")
    print(f"Décimal     : {n}")
    print(f"Hexadécimal : {hex(n)[2:].upper()}")

while True:
    base = input("\nBase de départ (2, 8, 10, 16) ou q pour quitter : ").strip()
    if base == "q":
        break
    if base not in BASES:
        print("Base invalide.")
        continue
    nombre = input("Nombre : ").strip()
    try:
        convertir(nombre, BASES[base])
    except ValueError:
        print(f"'{nombre}' n'est pas un nombre valide en base {base}.")
